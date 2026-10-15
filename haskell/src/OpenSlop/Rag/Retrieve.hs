-- | Question in, cited answer out.
--
-- 'retrieve' embeds the question as a query and runs the hybrid search.
-- 'answer' numbers the hits as sources, sends them with the question to a
-- LAN chat model, and returns the reply with the sources it was given.
-- Both take 'Lan' servers only; see "OpenSlop.Rag.Locality".
--
-- The prompt tells the model to cite sources by number and to say when the
-- sources do not hold the answer. 'citedSources' reads the numbers back out
-- of the reply, so a caller can show which sources were used and flag a
-- reply that cites none or cites a number it was never given.
module OpenSlop.Rag.Retrieve
  ( Retrieval (..)
  , retrieve
  , Chat (..)
  , chat
  , Answer (..)
  , answer
  , buildPrompt
  , citedSources
  ) where

import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue (Engine (..), engineName)
import OpenSlop.Http (Auth (..), Client, describeFailure, postJsonWithin)
import OpenSlop.Rag.Embed (Embedder (..), Purpose (..), embed)
import OpenSlop.Rag.Locality (Lan, lanUrl)
import OpenSlop.Rag.Store (Connection, Hit (..), search)

data Retrieval = Retrieval
  { depth :: Int
  -- ^ candidates taken from each half of the hybrid search
  , limit :: Int
  -- ^ hits kept after fusion
  }

retrieve :: Client -> Connection -> Embedder -> Retrieval -> Text -> IO (Either Text [Hit])
retrieve client conn e r question =
  embed client e ForQuery [question] >>= \case
    Left err -> pure (Left err)
    Right [v] -> Right <$> search conn e.model v question r.depth r.limit
    Right _ -> pure (Left "the embedding server returned no vector for the question")

data Chat = Chat
  { server :: Lan
  , engine :: Engine
  , model :: Text
  , ctx :: Int
  -- ^ the window asked of ollama; llama-server uses its own
  }

chat :: Lan -> Engine -> Text -> Int -> Either Text Chat
chat server engine model ctx = case engine of
  HailoOllama -> Left "hailo-ollama's 2048-token window cannot hold sources and a question"
  _ -> Right Chat {server, engine, model, ctx}

data Answer = Answer
  { text :: Text
  , sources :: [Hit]
  , cited :: [Int]
  -- ^ source numbers the reply cites, 1-based, in the range given
  , invented :: [Int]
  -- ^ source numbers the reply cites that were never given
  }

buildPrompt :: Text -> [Hit] -> (Text, Text)
buildPrompt question hits = (system, user)
  where
    system =
      T.unlines
        [ "You answer questions about the user's own files using only the numbered sources given."
        , "Cite every claim with the source number in square brackets, like [2]."
        , "If the sources do not contain the answer, say that they do not, and do not guess."
        , "Do not cite a number that is not in the list."
        ]
    user =
      T.unlines (zipWith source [1 :: Int ..] hits)
        <> "\nQuestion: "
        <> question
    source n h =
      "["
        <> T.pack (show n)
        <> "] "
        <> h.path
        <> (if T.null h.heading then "" else " (" <> h.heading <> ")")
        <> " lines "
        <> T.pack (show h.lineFrom)
        <> "-"
        <> T.pack (show h.lineTo)
        <> "\n"
        <> h.body
        <> "\n"

-- | Every [n] or [n, m] in the reply.
citedSources :: Text -> [Int]
citedSources = sort . nub . go
  where
    go t = case T.breakOn "[" t of
      (_, rest) | T.null rest -> []
      (_, rest) ->
        let inner = T.takeWhile (/= ']') (T.drop 1 rest)
            after = T.drop 1 (T.dropWhile (/= ']') (T.drop 1 rest))
            nums =
              [ read (T.unpack n)
              | piece <- T.splitOn "," inner
              , let n = T.strip piece
              , not (T.null n)
              , T.length n <= 4
              , T.all isDigit n
              ]
            valid = T.all (\c -> isDigit c || c == ',' || c == ' ') inner && not (T.null inner)
         in (if valid then nums else []) <> go after

newtype OllamaChat = OllamaChat Text

instance FromJSON OllamaChat where
  parseJSON = withObject "ollama chat reply" \o -> do
    m <- o .: "message"
    OllamaChat <$> withObject "message" (.: "content") m

newtype OpenAIChat = OpenAIChat Text

instance FromJSON OpenAIChat where
  parseJSON = withObject "chat completion" \o -> do
    choices <- o .: "choices"
    case choices of
      (c : _) -> do
        m <- withObject "choice" (.: "message") c
        OpenAIChat <$> withObject "message" (.: "content") m
      [] -> fail "no choices"

answer :: Client -> Chat -> Text -> [Hit] -> IO (Either Text Answer)
answer client c question hits = do
  let (system, user) = buildPrompt question hits
      messages =
        [ object ["role" .= ("system" :: Text), "content" .= system]
        , object ["role" .= ("user" :: Text), "content" .= user]
        ]
      (path, body) = case c.engine of
        LlamaServer ->
          ( "/v1/chat/completions"
          , object ["model" .= c.model, "messages" .= messages, "stream" .= False, "temperature" .= (0.2 :: Double)] :: Value
          )
        _ ->
          ( "/api/chat"
          , object
              [ "model" .= c.model
              , "messages" .= messages
              , "stream" .= False
              , "keep_alive" .= ("30m" :: Text)
              , "options" .= object ["num_ctx" .= c.ctx, "temperature" .= (0.2 :: Double)]
              ]
          )
  r <- postJsonWithin Nothing client NoAuth (lanUrl c.server) path body
  pure case r of
    Left f -> Left (engineName c.engine <> " chat: " <> describeFailure f)
    Right raw ->
      let decoded = case c.engine of
            LlamaServer -> (\(OpenAIChat t) -> t) <$> Aeson.eitherDecode raw
            _ -> (\(OllamaChat t) -> t) <$> Aeson.eitherDecode raw
       in case decoded of
            Left err -> Left ("unreadable chat reply: " <> T.pack err)
            Right text ->
              let ns = citedSources text
                  inRange n = n >= 1 && n <= length hits
               in Right
                    Answer
                      { text
                      , sources = hits
                      , cited = filter inRange ns
                      , invented = filter (not . inRange) ns
                      }
