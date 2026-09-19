-- | What each server dialect accepts and what it answers.
--
-- A 'Request' is built per engine, so an option that one server would answer
-- 500 to cannot be sent to it: 'HailoOllama' has no options field to fill.
-- A 'Reply' is one parsed line of the response, and 'Summary' is what a
-- finished exchange is reduced to, in engine-neutral terms.
module OpenSlop.Engine
  ( Request (..)
  , Prompt (..)
  , Sampling (..)
  , Reply (..)
  , FinalInfo (..)
  , Summary (..)
  , buildRequest
  , requestPath
  , parseReply
  , summarise
  , tagsPath
  , parseTags
  , ServedModel (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import OpenSlop.Catalogue (Engine (..))

-- | The instruction and the text, kept apart so an engine with a system
-- field can use it and one without can join them.
data Prompt = Prompt
  { instruction :: Text
  , header :: Text
  -- ^ the part header, "Part 3 of 34. ...", or empty
  , text :: Text
  }
  deriving stock (Show, Eq)

data Sampling = Sampling
  { ctx :: Int
  , predict :: Int
  , temperature :: Maybe Double
  , seed :: Maybe Int
  }
  deriving stock (Show, Eq)

-- | A request the named engine is known to accept.
data Request
  = OllamaGenerate Text Prompt Sampling Bool
  -- ^ model, prompt, sampling, stream
  | HailoGenerate Text Prompt
  -- ^ model, prompt, stream:false. Nothing else is verified against
  -- hailo-ollama, and unrecognised fields have produced a 500.
  | LlamaCompletion Prompt Sampling Bool
  -- ^ llama-server's native /completion. One model per server, so no model
  -- field; its context is fixed at start, so ctx is not sent.
  deriving stock (Show, Eq)

joined :: Prompt -> Text
joined p = T.intercalate "\n\n" (filter (not . T.null) [p.instruction, p.header, p.text])

joinedNoInstruction :: Prompt -> Text
joinedNoInstruction p = T.intercalate "\n\n" (filter (not . T.null) [p.header, p.text])

buildRequest :: Engine -> Text -> Prompt -> Sampling -> Bool -> Request
buildRequest engine model prompt sampling stream = case engine of
  Ollama -> OllamaGenerate model prompt sampling stream
  HailoOllama -> HailoGenerate model prompt
  LlamaServer -> LlamaCompletion prompt sampling stream

requestPath :: Request -> ByteString
requestPath = \case
  OllamaGenerate {} -> "/api/generate"
  HailoGenerate {} -> "/api/generate"
  LlamaCompletion {} -> "/completion"

instance ToJSON Request where
  toJSON = \case
    OllamaGenerate model prompt sampling stream ->
      object
        ( [ "model" .= model
          , "prompt" .= joinedNoInstruction prompt
          , "stream" .= stream
          , "options"
              .= object
                ( [ "num_ctx" .= sampling.ctx
                  , "num_predict" .= sampling.predict
                  ]
                    <> maybe [] (\t -> ["temperature" .= t]) sampling.temperature
                    <> maybe [] (\s -> ["seed" .= s]) sampling.seed
                )
          ]
            <> ["system" .= prompt.instruction | not (T.null prompt.instruction)]
        )
    HailoGenerate model prompt ->
      object ["model" .= model, "prompt" .= joined prompt, "stream" .= False]
    LlamaCompletion prompt sampling stream ->
      object
        ( [ "prompt" .= joined prompt
          , "stream" .= stream
          , "n_predict" .= sampling.predict
          , "cache_prompt" .= True
          ]
            <> maybe [] (\t -> ["temperature" .= t]) sampling.temperature
            <> maybe [] (\s -> ["seed" .= s]) sampling.seed
        )

-- | One line of a response, in engine-neutral terms. Streaming servers send
-- many; non-streaming ones send one 'Final'.
data Reply
  = Token Text
  | Final Text FinalInfo
  | ServerError Text
  deriving stock (Show, Eq)

data FinalInfo = FinalInfo
  { promptTokens :: Maybe Int
  , outputTokens :: Maybe Int
  , promptNs :: Maybe Double
  , outputNs :: Maybe Double
  , loadNs :: Maybe Double
  , hitLimit :: Bool
  -- ^ output stopped at the predict cap
  , serverTruncated :: Bool
  -- ^ the server itself reported cutting the prompt (llama-server does)
  }
  deriving stock (Show, Eq)

-- | Parse one response line. Handles ollama's NDJSON, hailo-ollama's single
-- object, and llama-server's SSE ("data: {...}") or plain JSON.
parseReply :: Engine -> ByteString -> Maybe Reply
parseReply engine raw0 = do
  let raw = fromMaybe raw0 (B.stripPrefix "data: " raw0)
  v <- Aeson.decodeStrict raw
  parseMaybe (replyParser engine) v

replyParser :: Engine -> Value -> Parser Reply
replyParser engine = Aeson.withObject "reply" \o -> do
  err <- o .:? "error"
  case err of
    Just (String e) -> pure (ServerError e)
    Just other -> pure (ServerError (T.pack (show other)))
    Nothing -> case engine of
      LlamaServer -> do
        content <- o .:? "content" .!= ""
        stop <- o .:? "stop" .!= False
        if not stop
          then pure (Token content)
          else do
            timings <- o .:? "timings"
            promptMs <- maybe (pure Nothing) (.:? "prompt_ms") timings
            predMs <- maybe (pure Nothing) (.:? "predicted_ms") timings
            stopType <- o .:? "stop_type" .!= ("" :: Text)
            info <-
              FinalInfo
                <$> o .:? "tokens_evaluated"
                <*> o .:? "tokens_predicted"
                <*> pure (fmap (* 1e6) promptMs)
                <*> pure (fmap (* 1e6) predMs)
                <*> pure Nothing
                <*> pure (stopType == "limit")
                <*> (o .:? "truncated" .!= False)
            pure (Final content info)
      _ -> do
        response <- o .:? "response" .!= ""
        done <- o .:? "done" .!= False
        if not done
          then pure (Token response)
          else do
            reason <- o .:? "done_reason" .!= ("" :: Text)
            info <-
              FinalInfo
                <$> o .:? "prompt_eval_count"
                <*> o .:? "eval_count"
                <*> o .:? "prompt_eval_duration"
                <*> o .:? "eval_duration"
                <*> o .:? "load_duration"
                <*> pure (reason == "length")
                <*> pure False
            pure (Final response info)
  where
    (.!=) :: Parser (Maybe a) -> a -> Parser a
    p .!= d = fromMaybe d <$> p

-- | The whole exchange, reduced.
data Summary = Summary
  { output :: Text
  , final :: Maybe FinalInfo
  -- ^ Nothing when the stream never reached its final line
  , errorText :: Maybe Text
  }
  deriving stock (Show, Eq)

summarise :: [Reply] -> Summary
summarise rs =
  Summary
    { output = T.concat [t | Token t <- rs] <> T.concat [t | Final t _ <- rs]
    , final = case [i | Final _ i <- rs] of
        (i : _) -> Just i
        [] -> Nothing
    , errorText = case [e | ServerError e <- rs] of
        (e : _) -> Just e
        [] -> Nothing
    }

-- | Where a backend lists its models.
tagsPath :: Engine -> ByteString
tagsPath = \case
  LlamaServer -> "/v1/models"
  _ -> "/api/tags"

data ServedModel = ServedModel
  { name :: Text
  , details :: Value
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Parse a tags listing. ollama and hailo-ollama: {models:[{name,details}]}.
-- llama-server: OpenAI-shaped {data:[{id}]}.
parseTags :: Engine -> BL.ByteString -> Maybe [ServedModel]
parseTags engine body = do
  v <- Aeson.decode body
  parseMaybe (p engine) v
  where
    p LlamaServer = Aeson.withObject "models" \o -> do
      ds <- o .: "data"
      pure (mapMaybe (parseMaybe (Aeson.withObject "m" \m -> ServedModel <$> m .: "id" <*> pure (Object mempty))) ds)
    p _ = Aeson.withObject "tags" \o -> do
      ms <- o .:? "models"
      pure
        ( mapMaybe
            (parseMaybe (Aeson.withObject "m" \m -> ServedModel <$> m .: "name" <*> (fromMaybe (Object mempty) <$> m .:? "details")))
            (fromMaybe [] ms)
        )
