-- | Text to vectors, through a LAN embedding server.
--
-- Two dialects: ollama's /api/embed (batch input, one vector per input) and
-- llama-server's OpenAI-shaped /v1/embeddings (llama-server started with
-- --embedding). hailo-ollama serves no embedding model and is refused.
--
-- Some embedding models are trained with a task prefix and retrieve worse
-- without it; 'prefixFor' carries the ones in use. A model not listed gets
-- no prefix.
module OpenSlop.Rag.Embed
  ( Purpose (..)
  , Embedder (..)
  , embedder
  , embed
  , prefixFor
  , vectorLiteral
  ) where

import Data.Aeson (FromJSON (..), Value, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue (Engine (..), engineName)
import OpenSlop.Http (Auth (..), Client, describeFailure, postJsonWithin)
import OpenSlop.Rag.Locality (Lan, lanUrl)

data Purpose = ForDocument | ForQuery
  deriving stock (Eq, Show)

data Embedder = Embedder
  { server :: Lan
  , engine :: Engine
  , model :: Text
  }

-- | Refuses an engine that has no embedding route.
embedder :: Lan -> Engine -> Text -> Either Text Embedder
embedder server engine model = case engine of
  HailoOllama -> Left "hailo-ollama serves no embedding model"
  _ -> Right Embedder {server, engine, model}

prefixFor :: Text -> Purpose -> Text
prefixFor model purpose
  | "nomic-embed" `T.isInfixOf` m = case purpose of
      ForDocument -> "search_document: "
      ForQuery -> "search_query: "
  | "mxbai-embed" `T.isInfixOf` m || "bge-" `T.isInfixOf` m = case purpose of
      ForDocument -> ""
      ForQuery -> "Represent this sentence for searching relevant passages: "
  | "snowflake-arctic-embed" `T.isInfixOf` m = case purpose of
      ForDocument -> ""
      ForQuery -> "Represent this sentence for searching relevant passages: "
  | otherwise = ""
  where
    m = T.toLower model

newtype OllamaEmbeds = OllamaEmbeds [[Double]]

instance FromJSON OllamaEmbeds where
  parseJSON = withObject "ollama embed reply" \o -> OllamaEmbeds <$> o .: "embeddings"

newtype OpenAIEmbeds = OpenAIEmbeds [[Double]]

instance FromJSON OpenAIEmbeds where
  parseJSON = withObject "embeddings reply" \o -> do
    rows <- o .: "data"
    OpenAIEmbeds <$> traverse (withObject "embedding row" (.: "embedding")) rows

-- | One vector per input, in input order. Inputs are sent in one request;
-- the caller decides the batch size.
embed :: Client -> Embedder -> Purpose -> [Text] -> IO (Either Text [[Double]])
embed _ _ _ [] = pure (Right [])
embed client e purpose texts = do
  let inputs = map (prefixFor e.model purpose <>) texts
      (path, body) = case e.engine of
        LlamaServer ->
          ("/v1/embeddings", object ["model" .= e.model, "input" .= inputs] :: Value)
        _ ->
          ( "/api/embed"
          , object
              [ "model" .= e.model
              , "input" .= inputs
              , "truncate" .= True
              , "keep_alive" .= ("30m" :: Text)
              ]
          )
  r <- postJsonWithin (Just 1800) client NoAuth (lanUrl e.server) path body
  pure case r of
    Left f -> Left (engineName e.engine <> " embed: " <> describeFailure f)
    Right raw ->
      let decoded = case e.engine of
            LlamaServer -> (\(OpenAIEmbeds v) -> v) <$> Aeson.eitherDecode raw
            _ -> (\(OllamaEmbeds v) -> v) <$> Aeson.eitherDecode raw
       in case decoded of
            Left err -> Left ("unreadable embedding reply: " <> T.pack err)
            Right vs
              | length vs /= length texts ->
                  Left ("asked for " <> tshow (length texts) <> " vectors, got " <> tshow (length vs))
              | otherwise -> case vs of
                  (v : rest)
                    | any ((/= length v) . length) rest -> Left "vectors of different lengths in one reply"
                    | null v -> Left "empty vector"
                  _ -> Right vs
  where
    tshow = T.pack . show

-- | pgvector's text form: [x,y,z].
vectorLiteral :: [Double] -> Text
vectorLiteral v = "[" <> T.intercalate "," (map (T.pack . show) v) <> "]"
