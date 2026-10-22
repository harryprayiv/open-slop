-- | The subset of OpenAI's chat-completions dialect the gateway speaks.
--
-- Grace's @prompt@ keyword, and every other OpenAI-compatible client, sends
-- this shape and decodes the answer with the @openai@ bindings. What is
-- accepted is what a text-in, text-or-JSON-out request needs: messages with
-- string content or text parts, a response_format, a token cap, temperature,
-- seed and reasoning effort. Anything else a client could ask for (tools,
-- images, audio, logprobs, several choices, streaming) is refused by name
-- with a 400, so a request is either served as written or rejected, never
-- served with a field quietly dropped.
--
-- A message's name is kept by writing it at the top of the content. Grace
-- labels its messages ("Instructions", "Type", "Attempt", "Error") so the
-- model can tell the required type from the last attempt and the compiler's
-- complaint about it, and none of the local backends' chat templates show a
-- name field to the model.
--
-- Assistant messages are the exception and keep only their text. A model
-- reads its own earlier turns as examples of what to write, so a label on
-- them is copied: on 2026-10-21 qwen2.5-coder-7b answered every repair of
-- an import prompt with "Attempt:" on its first line, because its failed
-- attempt had been shown back to it as "Attempt:" followed by the code, and
-- Grace's parser then failed on the label. The system message after each
-- attempt still says "Error:", so the model can tell its attempt from the
-- complaint.
module OpenSlop.OpenAI
  ( Role (..)
  , roleText
  , Message (..)
  , ResponseFormat (..)
  , Effort (..)
  , responseFormatValue
  , ChatRequest (..)
  , FinishReason (..)
  , Usage (..)
  , ChatResponse (..)
  , ApiError (..)
  , apiErrorValue
  , invalidRequest
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

data Role = RoleSystem | RoleUser | RoleAssistant
  deriving stock (Eq, Show)

roleText :: Role -> Text
roleText = \case
  RoleSystem -> "system"
  RoleUser -> "user"
  RoleAssistant -> "assistant"

-- | "developer" is OpenAI's newer name for the system role and is read as
-- one. "tool" and "function" need tool calling, which no backend here does.
instance FromJSON Role where
  parseJSON = withText "role" \case
    "system" -> pure RoleSystem
    "developer" -> pure RoleSystem
    "user" -> pure RoleUser
    "assistant" -> pure RoleAssistant
    other -> fail ("message role " <> T.unpack other <> " is not supported")

data Message = Message
  { role :: Role
  , content :: Text
  }
  deriving stock (Eq, Show)

-- | Content is a string, or a list of parts of which only text parts are
-- accepted; their texts are joined with newlines. The openai bindings send
-- the list form. A name becomes the content's first line, followed by a
-- colon, except on an assistant message (see the module header).
instance FromJSON Message where
  parseJSON = withObject "message" \o -> do
    role <- o .: "role"
    c <- o .:? "content"
    body <- case c of
      Just (String t) -> pure t
      Just (Array parts) -> T.intercalate "\n" <$> traverse textPart (toList parts)
      Just Null -> fail "a message with null content (a tool call) is not supported"
      Nothing -> fail "a message has no content"
      Just _ -> fail "message content must be a string or a list of text parts"
    name <- o .:? "name"
    let content = case T.strip <$> name of
          Just n | not (T.null n), role /= RoleAssistant -> n <> ":\n" <> body
          _ -> body
    pure Message {role, content}
    where
      textPart = withObject "content part" \p -> do
        ty <- p .: "type"
        if ty == ("text" :: Text)
          then p .: "text"
          else fail ("content part type " <> T.unpack ty <> " is not supported; only text")

instance ToJSON Message where
  toJSON m = object ["role" .= roleText m.role, "content" .= m.content]

data ResponseFormat
  = FormatText
  | FormatJsonObject
  | FormatJsonSchema Text Value
  -- ^ name and schema. This is what Grace sends for an annotated prompt:
  -- the result type compiled to JSON Schema, with strict set.
  deriving stock (Eq, Show)

instance FromJSON ResponseFormat where
  parseJSON = withObject "response_format" \o -> do
    ty <- o .: "type"
    case ty :: Text of
      "text" -> pure FormatText
      "json_object" -> pure FormatJsonObject
      "json_schema" -> do
        js <- o .: "json_schema"
        withObject "json_schema" (\j -> FormatJsonSchema <$> (fromMaybe "result" <$> j .:? "name") <*> j .: "schema") js
      other -> fail ("response_format type " <> T.unpack other <> " is not supported")

-- | The OpenAI form, for a backend that takes it as-is.
responseFormatValue :: ResponseFormat -> Value
responseFormatValue = \case
  FormatText -> object ["type" .= ("text" :: Text)]
  FormatJsonObject -> object ["type" .= ("json_object" :: Text)]
  FormatJsonSchema name schema ->
    object
      [ "type" .= ("json_schema" :: Text)
      , "json_schema" .= object ["name" .= name, "schema" .= schema, "strict" .= True]
      ]

-- | OpenAI's reasoning_effort, which Grace's prompt sends when a stage sets
-- `effort`. "none" is read as Minimal.
data Effort = Minimal | Low | Medium | High
  deriving stock (Eq, Show)

instance FromJSON Effort where
  parseJSON = withText "reasoning_effort" \case
    "minimal" -> pure Minimal
    "none" -> pure Minimal
    "low" -> pure Low
    "medium" -> pure Medium
    "high" -> pure High
    other -> fail ("reasoning_effort " <> T.unpack other <> " is not one of minimal, low, medium, high")

data ChatRequest = ChatRequest
  { model :: Text
  , messages :: [Message]
  , responseFormat :: Maybe ResponseFormat
  , maxTokens :: Maybe Int
  , temperature :: Maybe Double
  , seed :: Maybe Int
  , effort :: Maybe Effort
  -- ^ how the backend is told is in "OpenSlop.Gateway.Translate"
  }
  deriving stock (Eq, Show)

-- | Fields the gateway cannot honour fail the parse by name. Fields that do
-- not change the answer (user, metadata, store, service_tier) are ignored.
instance FromJSON ChatRequest where
  parseJSON = withObject "chat completion request" \o -> do
    mapM_ (refuse o) unsupported
    stream <- fromMaybe False <$> o .:? "stream"
    if stream then fail "stream is not supported by the gateway; send stream: false" else pure ()
    n <- fromMaybe (1 :: Int) <$> o .:? "n"
    if n /= 1 then fail "n other than 1 is not supported" else pure ()
    model <- o .: "model"
    messages <- o .: "messages"
    if null messages then fail "messages is empty" else pure ()
    responseFormat <- o .:? "response_format"
    mct <- o .:? "max_completion_tokens"
    mt <- o .:? "max_tokens"
    temperature <- o .:? "temperature"
    seed <- o .:? "seed"
    effort <- o .:? "reasoning_effort"
    pure ChatRequest {model, messages, responseFormat, maxTokens = maybe mt Just mct, temperature, seed, effort}
    where
      unsupported = ["tools", "functions", "tool_choice", "logprobs", "top_logprobs", "audio", "modalities", "prediction", "web_search_options"]
      refuse :: KeyMap.KeyMap Value -> Text -> Parser ()
      refuse o k = case KeyMap.lookup (Key.fromText k) o of
        Nothing -> pure ()
        Just Null -> pure ()
        Just (Bool False) -> pure ()
        Just (Array a) | null a -> pure ()
        Just _ -> fail (T.unpack k <> " is not supported by the gateway")

data FinishReason = FinishStop | FinishLength
  deriving stock (Eq, Show)

data Usage = Usage
  { promptTokens :: Int
  , completionTokens :: Int
  }
  deriving stock (Eq, Show)

data ChatResponse = ChatResponse
  { responseId :: Text
  , created :: Int
  , model :: Text
  , content :: Text
  , finish :: FinishReason
  , usage :: Usage
  }
  deriving stock (Eq, Show)

-- | The fields the openai bindings' ChatCompletionObject decodes. Optional
-- ones are sent as null rather than omitted where the bindings model them
-- as Maybe, which accepts either.
instance ToJSON ChatResponse where
  toJSON r =
    object
      [ "id" .= r.responseId
      , "object" .= ("chat.completion" :: Text)
      , "created" .= r.created
      , "model" .= r.model
      , "system_fingerprint" .= Null
      , "service_tier" .= Null
      , "choices"
          .= [ object
                 [ "index" .= (0 :: Int)
                 , "message"
                     .= object
                       [ "role" .= ("assistant" :: Text)
                       , "content" .= r.content
                       , "refusal" .= Null
                       ]
                 , "finish_reason" .= case r.finish of
                     FinishStop -> "stop" :: Text
                     FinishLength -> "length"
                 , "logprobs" .= Null
                 ]
             ]
      , "usage"
          .= object
            [ "prompt_tokens" .= r.usage.promptTokens
            , "completion_tokens" .= r.usage.completionTokens
            , "total_tokens" .= (r.usage.promptTokens + r.usage.completionTokens)
            ]
      ]

-- | An error in OpenAI's shape: status, type, optional code, message.
data ApiError = ApiError
  { status :: Int
  , kind :: Text
  , code :: Maybe Text
  , message :: Text
  }
  deriving stock (Eq, Show)

apiErrorValue :: ApiError -> Value
apiErrorValue e =
  object
    [ "error"
        .= object
          [ "message" .= e.message
          , "type" .= e.kind
          , "code" .= e.code
          , "param" .= Null
          ]
    ]

invalidRequest :: Maybe Text -> Text -> ApiError
invalidRequest code message = ApiError {status = 400, kind = "invalid_request_error", code, message}