-- | Questions in, cited answers out, alone or as a conversation.
--
-- ============================================================================
-- ONE TURN
-- ============================================================================
--
--   1. With earlier turns, the chat model first rewrites the new question
--      as one that stands alone ("and the port?" becomes "what port does
--      the gateway listen on?"), because the search sees only the question
--      and a follow-up on its own finds nothing. Without earlier turns the
--      question is searched as asked.
--   2. 'retrieve' embeds that query and runs the hybrid search, within the
--      scope given, for up to 'depth' candidates.
--   3. 'relevant' drops hits that ranked poorly in both halves, and
--      'packSources' keeps as many of the rest as the model's capacity
--      leaves room for after the conversation and the answer. A model with
--      a 128K window gets far more sources than one with 4K; nothing here
--      fixes the number.
--   4. 'answerStream' sends the instructions with the numbered sources, the
--      earlier turns and the question, and streams the answer as it comes.
--      Answers are not capped; see "OpenSlop.Capacity".
--   5. 'citedSources' reads the source numbers back out of the answer, so a
--      caller can show what was used and flag an answer that cites nothing
--      or cites a number it was never given.
--
-- Every server here is a 'Lan'; see "OpenSlop.Rag.Locality".
module OpenSlop.Rag.Retrieve
  ( Retrieval (..)
  , retrieve
  , Chat (..)
  , Answer (..)
  , historyChars
  , relevant
  , packSources
  , condense
  , answerStream
  , buildMessages
  , citedSources
  , judgeCitations
  ) where

import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as B
import Data.Char (isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Capacity (Capacity (..), promptCharsWithin, unlimitedPredict)
import OpenSlop.Catalogue (Engine (..), engineName)
import OpenSlop.Http (Auth (..), Client, describeFailure, postLines)
import OpenSlop.Rag.Embed (Embedder (..), Purpose (..), embed)
import OpenSlop.Rag.Locality (Lan, lanUrl)
import OpenSlop.Rag.Store (Connection, Hit (..), search)

data Retrieval = Retrieval
  { depth :: Int
  -- ^ candidates taken from each half of the hybrid search
  , limit :: Int
  -- ^ hits returned after fusion, before packing
  , scope :: [Text]
  -- ^ path prefixes; empty means the whole index
  }

retrieve :: Client -> Connection -> Embedder -> Retrieval -> Text -> IO (Either Text [Hit])
retrieve client conn e r query =
  embed client e ForQuery [query] >>= \case
    Left err -> pure (Left err)
    Right [v] -> Right <$> search conn e.model v query r.scope r.depth r.limit
    Right _ -> pure (Left "the embedding server returned no vector for the question")

data Chat = Chat
  { server :: Lan
  , engine :: Engine
  , model :: Text
  }

data Answer = Answer
  { text :: Text
  , sources :: [Hit]
  , cited :: [Int]
  -- ^ source numbers the answer cites, 1-based, in the range given
  , invented :: [Int]
  -- ^ source numbers the answer cites that were never given
  , promptTokens :: Maybe Int
  -- ^ as the server counted them, when it says
  , promptChars :: Int
  }

instructions :: Text
instructions =
  T.unlines
    [ "You answer questions about the user's own files using the numbered sources below."
    , "Cite every claim that comes from a source with its number in square brackets, like [2]."
    , "If the sources do not contain the answer, say so plainly and say what they do contain; do not guess."
    , "Do not cite a number that is not in the list. Earlier turns of the conversation are context, not sources."
    ]

renderSource :: Int -> Hit -> Text
renderSource n h =
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

-- | Hits that ranked in the top ten of either half of the search. Reciprocal
-- rank fusion gives every candidate a score, so without a cut a large
-- window would be filled with the fortieth-best match, which costs reading
-- time and gives the model more to be misled by. A hit found by both halves
-- passes even when neither rank alone is in the top ten.
relevant :: [Hit] -> [Hit]
relevant = filter (\h -> h.score >= 1 / 70)

-- | The best hits that fit, in order, given the characters already taken
-- by the conversation and the question.
packSources :: Capacity -> Maybe Double -> Int -> [Hit] -> [Hit]
packSources cap maxWait taken hits = go (budget - T.length instructions) (zip [1 ..] hits)
  where
    budget = promptCharsWithin cap 128 maxWait - taken
    go _ [] = []
    go room ((n, h) : rest)
      | size <= room = h : go (room - size) rest
      | otherwise = []
      where
        size = T.length (renderSource n h) + 1

-- | The messages for one turn: instructions and sources as the system
-- message, the earlier turns that fit, then the question. Earlier turns are
-- dropped oldest first so that they take at most half the prompt.
buildMessages :: Capacity -> Maybe Double -> [(Text, Text)] -> Text -> [Hit] -> ([Value], Int)
buildMessages cap maxWait history question hits = (msgs, chars)
  where
    system = instructions <> "\n" <> T.unlines (zipWith renderSource [1 ..] hits)
    half = promptCharsWithin cap 128 maxWait `div` 2
    kept = keepNewest half history
    msgs =
      [object ["role" .= ("system" :: Text), "content" .= system]]
        <> [object ["role" .= r, "content" .= c] | (r, c) <- kept]
        <> [object ["role" .= ("user" :: Text), "content" .= question]]
    chars = T.length system + sum [T.length c + 16 | (_, c) <- kept] + T.length question

keepNewest :: Int -> [(Text, Text)] -> [(Text, Text)]
keepNewest budget = reverse . go 0 . reverse
  where
    go _ [] = []
    go used ((r, c) : rest)
      | used + T.length c + 16 > budget = []
      | otherwise = (r, c) : go (used + T.length c + 16) rest

-- | The characters the conversation and question will take, for packing
-- the sources around them.
historyChars :: Capacity -> Maybe Double -> [(Text, Text)] -> Text -> Int
historyChars cap maxWait history question =
  sum [T.length c + 16 | (_, c) <- keepNewest (promptCharsWithin cap 128 maxWait `div` 2) history] + T.length question

-- | Rewrite a follow-up as a question that stands alone, using the
-- conversation. With no history the question is returned unchanged.
condense :: Client -> Chat -> Capacity -> [(Text, Text)] -> Text -> IO (Either Text Text)
condense _ _ _ [] q = pure (Right q)
condense client c cap history q = do
  let recent = keepNewest (promptCharsWithin cap 128 Nothing `div` 2) history
      convo = T.unlines [(if r == "user" then "User: " else "Assistant: ") <> t | (r, t) <- recent]
      msgs =
        [ object
            [ "role" .= ("system" :: Text)
            , "content"
                .= ( "Rewrite the user's last question so that it can be understood without the conversation, "
                       <> "for a search over their files. Reply with the rewritten question only, on one line." :: Text
                   )
            ]
        , object ["role" .= ("user" :: Text), "content" .= ("Conversation:\n" <> convo <> "\nLast question: " <> q)]
        ]
  out <- newIORef ("" :: Text)
  r <- streamChat client c cap msgs (Just 200) (\t -> modifyIORef' out (<> t)) (const (pure ()))
  rewritten <- T.strip . stripThink <$> readIORef out
  pure case r of
    Left e -> Left e
    Right ()
      | T.null rewritten -> Right q
      | otherwise -> Right (T.takeWhile (/= '\n') rewritten)
  where
    stripThink t = case T.breakOn "</think>" t of
      (_, rest) | not (T.null rest) -> T.drop 8 rest
      _ -> t

-- | Send one turn and stream the answer to the callback as it arrives.
answerStream
  :: Client
  -> Chat
  -> Capacity
  -> Maybe Double
  -> [(Text, Text)]
  -> Text
  -> [Hit]
  -> (Text -> IO ())
  -> IO (Either Text Answer)
answerStream client c cap maxWait history question hits onText = do
  let (msgs, chars) = buildMessages cap maxWait history question hits
  out <- newIORef ("" :: Text)
  counted <- newIORef Nothing
  r <- streamChat client c cap msgs Nothing (\t -> modifyIORef' out (<> t) >> onText t) (writeIORef counted . Just)
  text <- readIORef out
  pt <- readIORef counted
  pure case r of
    Left e -> Left e
    Right () ->
      let (cited, invented) = judgeCitations (length hits) text
       in Right Answer {text, sources = hits, cited, invented, promptTokens = pt, promptChars = chars}

-- | Which cited numbers were given and which were not.
judgeCitations :: Int -> Text -> ([Int], [Int])
judgeCitations n text =
  let ns = citedSources text
      inRange k = k >= 1 && k <= n
   in (filter inRange ns, filter (not . inRange) ns)

-- | Stream a chat completion. The answer is not capped unless a cap is
-- given (used only for the one-line rewrite). The second callback gets the
-- prompt token count when the server reports one.
streamChat
  :: Client
  -> Chat
  -> Capacity
  -> [Value]
  -> Maybe Int
  -> (Text -> IO ())
  -> (Int -> IO ())
  -> IO (Either Text ())
streamChat client c cap msgs cap' onText onPrompt = do
  failure <- newIORef Nothing
  let promptTokens = ceiling (fromIntegral (sum [msgChars m | m <- msgs]) / cap.charsPerToken) :: Int
      predict = case cap' of
        Just n -> [("num_predict", n)]
        Nothing -> [(k, v) | Just (k, v) <- [unlimitedPredict c.engine cap promptTokens]]
      (path, body) = case c.engine of
        LlamaServer ->
          ( "/v1/chat/completions"
          , object
              ( ["messages" .= msgs, "stream" .= True, "cache_prompt" .= True, "temperature" .= (0.2 :: Double)]
                  <> ["max_tokens" .= n | Just n <- [cap']]
              )
          )
        _ ->
          ( "/api/chat"
          , object
              [ "model" .= c.model
              , "messages" .= msgs
              , "stream" .= True
              , "keep_alive" .= ("30m" :: Text)
              , "options"
                  .= object
                    ( [Key.fromText k .= v | (k, v) <- predict]
                        <> ["num_ctx" .= cap.window | c.engine == Ollama]
                        <> ["temperature" .= (0.2 :: Double)]
                    )
              ]
          )
      onLine raw = case decodeStrict (fromMaybe raw (B.stripPrefix "data: " raw)) of
        Just (Object o)
          | Just e <- KeyMap.lookup "error" o -> writeIORef failure (Just (render e))
          | otherwise -> do
              let v = Object o
              mapM_ onText (textAt ["message", "content"] v)
              case KeyMap.lookup "choices" o of
                Just (Array cs) | (ch : _) <- foldr (:) [] cs -> mapM_ onText (textAt ["delta", "content"] ch)
                _ -> pure ()
              mapM_ onPrompt (intAt ["prompt_eval_count"] v)
        _ -> pure ()
  r <- postLines client NoAuth (lanUrl c.server) path body onLine
  bad <- readIORef failure
  pure case (r, bad) of
    (Left f, _) -> Left (engineName c.engine <> " chat: " <> describeFailure f)
    (_, Just e) -> Left (engineName c.engine <> " chat: " <> e)
    _ -> Right ()
  where
    render = \case
      String t -> t
      other -> T.pack (show other)
    msgChars = \case
      Object o | Just (String t) <- KeyMap.lookup "content" o -> T.length t + 16
      _ -> 16

-- | Every [n] or [n, m] in the answer.
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
            valid = T.all (\ch -> isDigit ch || ch == ',' || ch == ' ') inner && not (T.null inner)
         in (if valid then nums else []) <> go after

pathTo :: [Text] -> Value -> Maybe Value
pathTo [] v = Just v
pathTo (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= pathTo ks
pathTo _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt p v = case pathTo p v of
  Just (String t) -> Just t
  _ -> Nothing

intAt :: [Text] -> Value -> Maybe Int
intAt p v = case pathTo p v of
  Just (Number n) -> Just (round (toRealFloat n :: Double))
  _ -> Nothing