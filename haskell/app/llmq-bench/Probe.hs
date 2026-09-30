-- | One timed, streamed request to a model, on any of the three engines.
--
-- Part of llmq-bench; Main's header says what is measured and why.
--
-- ============================================================================
-- WHY STREAMED
-- ============================================================================
--
-- A request that returns its answer in one piece has one number: the whole
-- wall clock, prompt reading and generation together, and the only way to
-- split them is to trust the server's own timings, which on 2026-09-26 put
-- 711 s of prefill inside a 258 s wall clock. A streamed request is timed
-- by the client at every piece that arrives, so one request gives both:
--
--   ttft       seconds from sending to the first generated piece: reading
--              the prompt, plus fixed overhead, plus one generated token
--   decode     generated tokens after the first, over the seconds between
--              the first piece and the last: generation alone
--
-- The token count is the server's own (eval_count, predicted_n) where it
-- gives one, and the number of pieces otherwise; every engine here sends
-- one token per piece.
--
-- ============================================================================
-- REASONING MODELS
-- ============================================================================
--
-- ollama sends a reasoning model's think block in message.thinking (or
-- thinking, on /api/generate), apart from message.content, and llama-server
-- sends it in delta.reasoning_content. Those pieces are generated tokens
-- like any other, so they count for ttft and decode. They are left out of
-- the answer text, which the schema and restraint checks read. On
-- 2026-09-30 deepseek-r1:1.5b spent all 64 tokens of every grid request
-- thinking; counting only content gave it no first token and no timings.
--
-- ============================================================================
-- THE REQUESTS
-- ============================================================================
--
--   ollama        POST /api/chat, NDJSON, with num_ctx set to the window
--                 llmq uses for the model. Without it ollama applies its own
--                 default, and a longer prompt is cut silently: the numbers
--                 then describe a shorter prompt than the one sent.
--   llama-server  POST /v1/chat/completions with stream, SSE, cache_prompt.
--   hailo-ollama  POST /api/generate, NDJSON; it cannot constrain output,
--                 so it is never asked for a schema.
--
-- Every request is deterministic: temperature 0, seed 1.
module Probe
  ( Request (..)
  , Trial (..)
  , streamAsk
  , decodeRate
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as B
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import OpenSlop.Catalogue (Backend (..), Endpoint (..), Engine (..))
import OpenSlop.Http (Auth (..), Client, describeFailure, postLines)
import System.Timeout (timeout)

data Request = Request
  { prompt :: Text
  , maxTokens :: Int
  , withSchema :: Bool
  , numCtx :: Maybe Int
  }

data Trial = Trial
  { started :: Double
  -- ^ monotonic clock at sending, for matching against machine samples
  , ended :: Double
  , total :: Double
  , ttft :: Maybe Double
  , lastPiece :: Maybe Double
  , pieces :: Int
  , promptTokens :: Maybe Int
  , completionTokens :: Maybe Int
  , text :: Text
  -- ^ the answer, without any think block
  , thinking :: Int
  -- ^ how many of the pieces were think block
  }

-- | Generated tokens per second after the first, from one trial. Nothing
-- when fewer than eight tokens came back, which is too few intervals to
-- time.
decodeRate :: Trial -> Maybe Double
decodeRate t = do
  first <- t.ttft
  lastT <- t.lastPiece
  let tokens = fromMaybe t.pieces t.completionTokens
      span' = lastT - first
  if tokens >= 8 && span' > 0 then Just (fromIntegral (tokens - 1) / span') else Nothing

streamAsk :: Client -> Int -> Endpoint -> Backend -> Text -> Request -> IO (Either Text Trial)
streamAsk client limit ep b model req = do
  firstRef <- newIORef Nothing
  lastRef <- newIORef Nothing
  piecesRef <- newIORef (0 :: Int)
  thinkingRef <- newIORef (0 :: Int)
  textRef <- newIORef []
  promptRef <- newIORef Nothing
  completionRef <- newIORef Nothing
  errRef <- newIORef Nothing
  t0 <- getMonotonicTime
  let timed = do
        tn <- getMonotonicTime
        modifyIORef' firstRef (maybe (Just (tn - t0)) Just)
        writeIORef lastRef (Just (tn - t0))
        modifyIORef' piecesRef (+ 1)
      answer t
        | T.null t = pure ()
        | otherwise = timed >> modifyIORef' textRef (t :)
      thought t
        | T.null t = pure ()
        | otherwise = timed >> modifyIORef' thinkingRef (+ 1)
      withJson raw k = case Aeson.decodeStrict (fromMaybe raw (B.stripPrefix "data: " raw)) of
        Just (Object o) -> case KeyMap.lookup "error" o of
          Just (String e) -> writeIORef errRef (Just e)
          Just e -> writeIORef errRef (Just (T.pack (show e)))
          Nothing -> k (Object o)
        _ -> pure ()
      ndjson field thinkField raw = withJson raw \v -> do
        maybe (pure ()) thought (textAt thinkField v)
        maybe (pure ()) answer (textAt field v)
        mapM_ (writeIORef promptRef . Just) (intAt ["prompt_eval_count"] v)
        mapM_ (writeIORef completionRef . Just) (intAt ["eval_count"] v)
      sse raw
        | B.isPrefixOf "data: [DONE]" raw = pure ()
        | otherwise = withJson raw \v -> do
            case pathTo ["choices"] v of
              Just (Array cs) | (c : _) <- foldr (:) [] cs -> do
                maybe (pure ()) thought (textAt ["delta", "reasoning_content"] c)
                maybe (pure ()) answer (textAt ["delta", "content"] c)
              _ -> pure ()
            mapM_ (writeIORef promptRef . Just) (intAt ["timings", "prompt_n"] v)
            mapM_ (writeIORef completionRef . Just) (intAt ["timings", "predicted_n"] v)
      schema =
        object
          [ "type" .= ("object" :: Text)
          , "properties" .= object ["answer" .= object ["type" .= ("string" :: Text)]]
          , "required" .= (["answer"] :: [Text])
          , "additionalProperties" .= False
          ]
      user = [object ["role" .= ("user" :: Text), "content" .= req.prompt]]
      (path, body, onLine) = case b.engine of
        Ollama ->
          ( "/api/chat"
          , object
              ( [ "model" .= model
                , "messages" .= user
                , "stream" .= True
                , "keep_alive" .= ("30m" :: Text)
                , "options"
                    .= object
                      ( ["num_predict" .= req.maxTokens, "temperature" .= (0 :: Int), "seed" .= (1 :: Int)]
                          <> ["num_ctx" .= c | Just c <- [req.numCtx]]
                      )
                ]
                  <> ["format" .= schema | req.withSchema]
              )
          , ndjson ["message", "content"] ["message", "thinking"]
          )
        LlamaServer ->
          ( "/v1/chat/completions"
          , object
              ( [ "model" .= model
                , "messages" .= user
                , "stream" .= True
                , "max_tokens" .= req.maxTokens
                , "temperature" .= (0 :: Int)
                , "seed" .= (1 :: Int)
                , "cache_prompt" .= True
                ]
                  <> [ "response_format"
                         .= object
                           [ "type" .= ("json_schema" :: Text)
                           , "json_schema" .= object ["name" .= ("probe" :: Text), "strict" .= True, "schema" .= schema]
                           ]
                     | req.withSchema
                     ]
              )
          , sse
          )
        HailoOllama ->
          ( "/api/generate"
          , object
              [ "model" .= model
              , "prompt" .= req.prompt
              , "stream" .= True
              , "options" .= object ["num_predict" .= req.maxTokens]
              ]
          , ndjson ["response"] ["thinking"]
          )
  r <- timeout (limit * 1000000) (postLines client NoAuth ep.url path body onLine)
  t1 <- getMonotonicTime
  err <- readIORef errRef
  case (r, err) of
    (Nothing, _) -> pure (Left ("no complete answer within " <> T.pack (show limit) <> " s"))
    (Just (Left f), _) -> pure (Left (describeFailure f))
    (_, Just e) -> pure (Left ("the server reported: " <> T.take 200 e))
    (Just (Right ()), Nothing) -> do
      first <- readIORef firstRef
      lastT <- readIORef lastRef
      n <- readIORef piecesRef
      txt <- T.concat . reverse <$> readIORef textRef
      pt <- readIORef promptRef
      ct <- readIORef completionRef
      th <- readIORef thinkingRef
      pure
        ( Right
            Trial
              { started = t0
              , ended = t1
              , total = t1 - t0
              , ttft = first
              , lastPiece = lastT
              , pieces = n
              , promptTokens = pt
              , completionTokens = ct
              , text = txt
              , thinking = th
              }
        )

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