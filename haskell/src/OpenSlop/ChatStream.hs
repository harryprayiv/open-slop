-- | One streamed chat request to a LAN server, ollama or llama-server.
--
-- Shared by llmq-index, which streams prose answers, and llmq-agent, which
-- streams a decision constrained to a JSON Schema. The answer is not capped
-- unless the request says so; see "OpenSlop.Capacity". The window comes
-- from the capacity, so ollama allocates what the model and the catalogue
-- allow and no request reloads the model with a different context.
--
-- A schema goes to ollama as `format` and to llama-server as an OpenAI
-- response_format. Both turn it into a grammar and sample only what it
-- allows. Thinking, when a model does it, arrives apart from the content
-- (ollama's message.thinking, llama-server's reasoning_content) and is
-- handed to its own callback, so it never mixes into the answer.
module OpenSlop.ChatStream
  ( Chat (..)
  , Ask (..)
  , plainAsk
  , Streamed (..)
  , ignoreStream
  , streamChat
  , streamChatTo
  ) where

import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as B
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Capacity (Capacity (..), unlimitedPredict)
import OpenSlop.Catalogue (Engine (..), engineName)
import OpenSlop.Http (Auth (..), Client, describeFailure, postLines)
import OpenSlop.Rag.Locality (Lan, lanUrl)

data Chat = Chat
  { server :: Lan
  , engine :: Engine
  , model :: Text
  }

data Ask = Ask
  { messages :: [Value]
  , schema :: Maybe Value
  -- ^ constrain the answer to this JSON Schema
  , outputCap :: Maybe Int
  -- ^ only for short rewrites; an answer is otherwise not capped
  , temperature :: Double
  }

plainAsk :: [Value] -> Ask
plainAsk messages = Ask {messages, schema = Nothing, outputCap = Nothing, temperature = 0.2}

-- | Where the pieces of a streamed answer go as they arrive.
data Streamed = Streamed
  { onText :: Text -> IO ()
  , onThinking :: Text -> IO ()
  , onPromptTokens :: Int -> IO ()
  }

ignoreStream :: Streamed
ignoreStream = Streamed (const (pure ())) (const (pure ())) (const (pure ()))

-- | Stream a chat completion to a text callback and a prompt-count
-- callback, dropping any thinking. 'streamChatTo' takes all three.
streamChat :: Client -> Chat -> Capacity -> Ask -> (Text -> IO ()) -> (Int -> IO ()) -> IO (Either Text ())
streamChat client c cap ask onText onPrompt =
  streamChatTo client c cap ask ignoreStream {onText, onPromptTokens = onPrompt}

streamChatTo :: Client -> Chat -> Capacity -> Ask -> Streamed -> IO (Either Text ())
streamChatTo client c cap ask out = do
  failure <- newIORef Nothing
  let promptTokens = ceiling (fromIntegral (sum [msgChars m | m <- ask.messages]) / cap.charsPerToken) :: Int
      predict = case ask.outputCap of
        Just n -> [("num_predict", n)]
        Nothing -> [(k, v) | Just (k, v) <- [unlimitedPredict c.engine cap promptTokens]]
      (path, body) = case c.engine of
        LlamaServer ->
          ( "/v1/chat/completions"
          , object
              ( [ "messages" .= ask.messages
                , "stream" .= True
                , "cache_prompt" .= True
                , "temperature" .= ask.temperature
                ]
                  <> ["max_tokens" .= n | Just n <- [ask.outputCap]]
                  <> [ "response_format"
                         .= object
                           [ "type" .= ("json_schema" :: Text)
                           , "json_schema" .= object ["name" .= ("result" :: Text), "schema" .= s, "strict" .= True]
                           ]
                     | Just s <- [ask.schema]
                     ]
              )
          )
        _ ->
          ( "/api/chat"
          , object
              ( [ "model" .= c.model
                , "messages" .= ask.messages
                , "stream" .= True
                , "keep_alive" .= ("30m" :: Text)
                , "options"
                    .= object
                      ( [Key.fromText k .= v | (k, v) <- predict]
                          <> ["num_ctx" .= cap.window | c.engine == Ollama]
                          <> ["temperature" .= ask.temperature]
                      )
                ]
                  <> ["format" .= s | Just s <- [ask.schema]]
              )
          )
      onLine raw = case decodeStrict (fromMaybe raw (B.stripPrefix "data: " raw)) of
        Just (Object o)
          | Just e <- KeyMap.lookup "error" o -> writeIORef failure (Just (render e))
          | otherwise -> do
              let v = Object o
              mapM_ out.onThinking (textAt ["message", "thinking"] v)
              mapM_ out.onText (textAt ["message", "content"] v)
              case KeyMap.lookup "choices" o of
                Just (Array cs) | (ch : _) <- toList cs -> do
                  mapM_ out.onThinking (textAt ["delta", "reasoning_content"] ch)
                  mapM_ out.onText (textAt ["delta", "content"] ch)
                _ -> pure ()
              mapM_ out.onPromptTokens (intAt ["prompt_eval_count"] v)
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
