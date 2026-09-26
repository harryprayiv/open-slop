-- | An OpenAI request, planned for one backend, and its answer read back.
--
-- Pure: a 'Target' and a 'ChatRequest' in, a 'Call' or an 'ApiError' out;
-- a backend's response body in, a 'Reply' out. The server module does the
-- I/O. Every decision about what a backend may be sent lives here, where
-- the test suite can reach it.
--
-- ============================================================================
-- WHAT EACH BACKEND GETS
-- ============================================================================
--
--   ollama        /api/chat. The messages as given; the catalogue's window
--                 as num_ctx, so no request can reload the model with a
--                 different context; a JSON Schema response_format becomes
--                 ollama's `format`, which constrains decoding to the
--                 schema. json_object becomes format "json".
--   llama-server  /v1/chat/completions, its own OpenAI route, which applies
--                 the model's chat template itself and constrains decoding
--                 to response_format with a grammar. Its window is fixed at
--                 start, so no context is sent.
--   hailo-ollama  /api/generate with the messages joined, because the NPU
--                 server takes one prompt. A response_format is refused:
--                 measured 2026-09-26, that server answers a request
--                 carrying a format field with HTTP 500 and "No suitable
--                 mapper found to deserialize the request body", and it has
--                 no OpenAI route at all (404 on /v1/models).
--
-- ============================================================================
-- THE WINDOW IS CHECKED BEFORE AND AFTER
-- ============================================================================
--
-- Before: the input's bytes against (ctx - output tokens) at the catalogue's
-- pessimistic bytes-per-token. That is the only guard on hailo-ollama, which
-- answers an overflowing prompt with garbage and HTTP 200 and reports no
-- prompt count. After: the backend's own prompt count against the window,
-- through the same judgement llmq applies to a part, because ollama drops the
-- front of an oversized prompt and still answers.
module OpenSlop.Gateway.Translate
  ( Call (..)
  , plan
  , Reply (..)
  , parseBackendReply
  , finalInfo
  ) where

import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import OpenSlop.Catalogue
import OpenSlop.Engine (FinalInfo (..))
import OpenSlop.Gateway.Route (Target (..))
import OpenSlop.OpenAI

data Call = Call
  { path :: ByteString
  , body :: Value
  , predict :: Int
  -- ^ the output cap actually sent
  }
  deriving stock (Show)

plan :: Target -> ChatRequest -> Either ApiError Call
plan t r = do
  let b = t.budget
      predict = fromMaybe b.predict r.maxTokens
      inputBytes = sum [BL.length (BL.fromStrict (TE.encodeUtf8 m.content)) | m <- r.messages]
      limit = floor (fromIntegral (b.ctx - predict) * b.bytesPerToken) :: Int
      temperature = maybe b.temperature Just r.temperature
  if predict < 1
    then Left (invalidRequest Nothing "max_completion_tokens must be at least 1")
    else Right ()
  if predict >= b.ctx
    then Left (invalidRequest (Just "context_length_exceeded") ("max_completion_tokens " <> tshow predict <> " leaves no room for input in " <> t.name <> "'s " <> tshow b.ctx <> "-token window"))
    else Right ()
  if fromIntegral inputBytes > limit
    then
      Left
        ( invalidRequest
            (Just "context_length_exceeded")
            ( "the messages are " <> tshow inputBytes <> " bytes; " <> t.name <> " holds about " <> tshow limit
                <> " bytes of input beside a " <> tshow predict <> "-token answer in its " <> tshow b.ctx <> "-token window"
            )
        )
    else Right ()
  case t.backend.engine of
    Ollama ->
      Right
        Call
          { path = "/api/chat"
          , predict
          , body =
              object
                ( [ "model" .= t.name
                  , "messages" .= r.messages
                  , "stream" .= False
                  , "options"
                      .= object
                        ( ["num_ctx" .= b.ctx, "num_predict" .= predict]
                            <> catMaybes [("temperature" .=) <$> temperature, ("seed" .=) <$> r.seed]
                        )
                  ]
                    <> case r.responseFormat of
                      Just (FormatJsonSchema _ schema) -> ["format" .= schema]
                      Just FormatJsonObject -> ["format" .= ("json" :: Text)]
                      _ -> []
                )
          }
    LlamaServer ->
      Right
        Call
          { path = "/v1/chat/completions"
          , predict
          , body =
              object
                ( [ "messages" .= r.messages
                  , "stream" .= False
                  , "max_tokens" .= predict
                  , -- Measured 2026-09-26 on oracle: a 4,700-token prompt
                    -- prefills in 1.0 s warm against about 219 s cold, so a
                    -- client that sends the same bundle in front of many
                    -- small questions pays for it once. llama-server keeps
                    -- the cache per slot; ollama ignores this field.
                    "cache_prompt" .= True
                  ]
                    <> catMaybes
                      [ ("temperature" .=) <$> temperature
                      , ("seed" .=) <$> r.seed
                      , ("response_format" .=) . responseFormatValue <$> r.responseFormat
                      ]
                )
          }
    HailoOllama -> do
      case r.responseFormat of
        Just FormatJsonSchema {} -> Left (unsupportedFormat t)
        Just FormatJsonObject -> Left (unsupportedFormat t)
        _ -> Right ()
      if any (\m -> m.role == RoleAssistant) r.messages
        then Left (invalidRequest Nothing (t.name <> " on hailo-ollama takes one prompt; a conversation with assistant turns is not supported"))
        else Right ()
      Right
        Call
          { path = "/api/generate"
          , predict
          , body =
              object
                [ "model" .= t.name
                , "prompt" .= T.intercalate "\n\n" [m.content | m <- r.messages, not (T.null m.content)]
                , "stream" .= False
                , "options" .= object ["num_predict" .= predict]
                ]
          }
  where
    unsupportedFormat target =
      invalidRequest
        (Just "response_format_unsupported")
        (target.name <> " is served by hailo-ollama, which cannot constrain output to a schema and answers 500 to a request carrying one; use a cpu or llamacpp model")

-- | A backend's answer, in the terms the OpenAI response and llmq's verdict
-- need.
data Reply = Reply
  { content :: Text
  , promptTokens :: Maybe Int
  , completionTokens :: Maybe Int
  , finish :: FinishReason
  }
  deriving stock (Eq, Show)

parseBackendReply :: Engine -> BL.ByteString -> Either Text Reply
parseBackendReply engine raw = case Aeson.eitherDecode raw of
  Left e -> Left ("the backend's answer is not JSON (" <> T.pack e <> ")")
  Right v -> either (Left . T.pack) Right (parseEither (parser engine) v)
  where
    parser :: Engine -> Value -> Parser Reply
    parser eng = withObject "reply" \o -> do
      err <- o .:? "error"
      case err of
        Just (String e) -> fail ("the backend said: " <> T.unpack e)
        Just (Object e) -> do
          m <- e .:? "message"
          fail ("the backend said: " <> T.unpack (fromMaybe "an error without a message" m))
        _ -> case eng of
          Ollama -> do
            msg <- o .: "message"
            content <- withObject "message" (.: "content") msg
            reason <- fromMaybe "" <$> o .:? "done_reason"
            Reply content <$> o .:? "prompt_eval_count" <*> o .:? "eval_count" <*> pure (finishOf reason)
          HailoOllama -> do
            content <- o .: "response"
            reason <- fromMaybe "" <$> o .:? "done_reason"
            Reply content Nothing <$> o .:? "eval_count" <*> pure (finishOf reason)
          LlamaServer -> do
            choices <- o .: "choices"
            case choices of
              (c : _) -> do
                msg <- c .: "message"
                content <- withObject "message" (\m -> fromMaybe "" <$> m .:? "content") msg
                reason <- fromMaybe "" <$> c .:? "finish_reason"
                usage <- o .:? "usage"
                pt <- maybe (pure Nothing) (.:? "prompt_tokens") usage
                ct <- maybe (pure Nothing) (.:? "completion_tokens") usage
                pure (Reply content pt ct (finishOf reason))
              [] -> fail "the backend returned no choices"
    finishOf :: Text -> FinishReason
    finishOf r = if r == "length" then FinishLength else FinishStop

-- | The reply as llmq's verdict reads a part's final line.
finalInfo :: Reply -> FinalInfo
finalInfo r =
  FinalInfo
    { promptTokens = r.promptTokens
    , outputTokens = r.completionTokens
    , promptNs = Nothing
    , outputNs = Nothing
    , loadNs = Nothing
    , hitLimit = r.finish == FinishLength
    , serverTruncated = False
    }

tshow :: (Show a) => a -> Text
tshow = T.pack . show