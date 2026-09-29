-- | Chatting with one model, or with several at once to compare them.
--
-- Part of llmq-models; Main describes the program.
--
-- ============================================================================
-- A CONVERSATION, NOT A QUERY
-- ============================================================================
--
-- Each participant keeps its own history, and every turn sends that whole
-- history to the model's server through the server's chat endpoint, which
-- applies the model's own chat template. Nothing goes through llmq: an
-- earlier version handed each question to `llmq ask`, which is one prompt
-- with no memory, so a reply to the model's answer arrived as an unrelated
-- new question.
--
--   ollama        POST /api/chat, NDJSON: message.content per line, the
--                 final line done with eval_count
--   llama-server  POST /v1/chat/completions with stream, SSE: each
--                 "data:" line a choices[0].delta.content, ending [DONE];
--                 cache_prompt is sent so each turn re-reads only the new
--                 message
--   hailo-ollama  POST /api/chat in ollama's shape. If the server refuses
--                 that route, the conversation falls back to /api/generate
--                 with the history written out as a transcript, and says so
--                 once.
--
-- ============================================================================
-- COMPARING MODELS
-- ============================================================================
--
-- With several participants, each message goes to each model in turn, and
-- each answers from its own history, so it is two or three separate
-- conversations that happen to receive the same user messages. They are
-- asked one after another, not at once: two models on oracle's CPU would
-- slow each other down and, at 8B, may not both fit in memory. The cost of
-- that is visible: comparing two large CPU models can make ollama unload
-- one to load the other on every turn, which shows as a load delay before
-- each answer. A CPU model against an NPU model runs on separate hardware
-- and has no such cost.
--
-- ============================================================================
-- STAYING INSIDE THE WINDOW
-- ============================================================================
--
-- A history outgrows a model's window, the NPU's 2,048 tokens soonest. Before
-- each turn the oldest exchanges are dropped until the history fits the
-- window less the reply budget, estimated with the backend's bytes per token,
-- and the screen says how many were dropped. Without that, ollama and
-- hailo-ollama would silently lose the front of the prompt instead.
module Chat (chatWith) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (IOException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as B
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Models
import OpenSlop.Http (Auth (..), Client, HttpFailure (..), describeFailure, postLines)
import Style
import System.IO

data Turn = Turn
  { role :: Text
  , content :: Text
  }

data Participant = Participant
  { row :: Row
  , url :: Text
  , history :: IORef [Turn]
  , hailoChat :: IORef Bool
  -- ^ whether hailo-ollama's /api/chat works; False after one refusal
  }

-- | Output tokens asked for per reply. Enough for a real answer; small
-- enough that a runaway model on a 2 tok/s backend stops within minutes.
replyBudget :: Int
replyBudget = 512

-- | Chat with the given models, each with the URL of its server, until the
-- user types /back or ends input. Returns to the caller's screen.
chatWith :: Client -> [(Row, Text)] -> IO ()
chatWith client targets = do
  leaveScreen
  ps <- mapM (\(r, u) -> Participant r u <$> newIORef [] <*> newIORef True) targets
  TIO.putStrLn ""
  TIO.putStrLn (bold (fg cAccent (if length ps > 1 then "comparing" else "chat")) <> "  " <> T.intercalate (fg cMuted "  vs  ") (map (label . (.row)) ps))
  TIO.putStrLn (fg cMuted "  /back returns to the models    /clear starts over    each message goes to every model listed")
  conversation client ps
  enterScreen

label :: Row -> Text
label r = fg (backendColour r.backend) "● " <> bold (fg cText (r.backend <> "/" <> r.model))

conversation :: Client -> [Participant] -> IO ()
conversation client ps = do
  TIO.putStr ("\n" <> fg cAccent "you ❯ ")
  hFlush stdout
  input <- try TIO.getLine :: IO (Either IOException Text)
  case T.strip <$> input of
    Left _ -> pure ()
    Right q
      | q `elem` ["/back", "/b", "/q", "/quit"] -> pure ()
      | q == "/clear" -> do
          forM_ ps \p -> writeIORef p.history []
          TIO.putStrLn (fg cMuted "  histories cleared")
          conversation client ps
      | T.null q -> conversation client ps
      | otherwise -> do
          forM_ ps \p -> turn client p q
          conversation client ps

-- | One user message to one participant, and its streamed answer.
turn :: Client -> Participant -> Text -> IO ()
turn client p q = do
  modifyIORef' p.history (<> [Turn "user" q])
  dropped <- fitWindow p
  TIO.putStrLn ""
  TIO.putStrLn (label p.row)
  when (dropped > 0) $
    TIO.putStrLn (fg cMuted ("  dropped the oldest " <> T.pack (show dropped) <> " messages to fit the window"))
  msgs <- readIORef p.history
  started <- getCurrentTime
  firstAt <- newEmptyMVar
  answer <- newMVar ("" :: Text)
  tokens <- newMVar (0 :: Int)
  reported <- newMVar (Nothing :: Maybe Int)
  failure <- newMVar (Nothing :: Maybe Text)
  notes <- newMVar ([] :: [Text])
  _ <- forkIO (spinner started firstAt)
  let onText t = unless (T.null t) do
        seen <- isJust <$> tryReadMVar firstAt
        unless seen do
          now <- getCurrentTime
          putMVar firstAt now
          threadDelay 60000
          TIO.putStr "\r\ESC[2K"
        TIO.putStr t
        hFlush stdout
        modifyMVar_ answer (pure . (<> t))
        modifyMVar_ tokens (pure . (+ 1))
      handlers =
        Handlers
          onText
          (\n -> modifyMVar_ reported (const (pure (Just n))))
          (\e -> modifyMVar_ failure (const (pure (Just e))))
          (\t -> modifyMVar_ notes (pure . (<> [t])))
  result <- send client p msgs handlers
  stopSpinner firstAt
  finished <- getCurrentTime
  err <- readMVar failure
  full <- readMVar answer
  pending <- readMVar notes
  case (result, err) of
    (Left e, _) -> TIO.putStrLn (fg cRed ("  no answer: " <> e))
    (_, Just e) -> TIO.putStrLn (fg cRed ("\n  server error: " <> e))
    _ -> do
      modifyIORef' p.history (<> [Turn "assistant" full])
      first <- tryReadMVar firstAt
      counted <- readMVar tokens
      n <- fromMaybe counted <$> readMVar reported
      let total = secs started finished
          wait = maybe total (secs started) first
          rate = fromIntegral n / max 0.1 (total - wait)
      TIO.putStrLn ""
      TIO.putStrLn
        ( fg cMuted
            ( "  " <> duration total <> " in all, first words after " <> duration wait
                <> ", "
                <> T.pack (show n)
                <> " tokens at "
                <> fmt "%.1f tok/s" rate
            )
        )
  forM_ pending \t -> TIO.putStrLn (fg cMuted ("  " <> t))
  where
    secs a b = realToFrac (diffUTCTime b a) :: Double

stopSpinner :: MVar UTCTime -> IO ()
stopSpinner firstAt = do
  seen <- isJust <$> tryReadMVar firstAt
  unless seen do
    now <- getCurrentTime
    putMVar firstAt now
    threadDelay 60000
    TIO.putStr "\r\ESC[2K"

-- | Drop the oldest messages, keeping the newest, until the history fits
-- the window less the reply budget. Returns how many were dropped.
fitWindow :: Participant -> IO Int
fitWindow p = do
  msgs <- readIORef p.history
  let window = case p.row.backend of
        "hailo" -> 2048
        _ -> min 16384 (fromMaybe 16384 p.row.window)
      budget = floor (fromIntegral (window - replyBudget - 128) * p.row.charsPerToken) :: Int
      size = sum . map (\t -> T.length t.content + 16)
      go ms n
        | size ms <= budget || length ms <= 1 = (ms, n)
        | otherwise = go (drop 1 ms) (n + 1)
      (kept, dropped) = go msgs 0
  writeIORef p.history kept
  pure dropped

data Handlers = Handlers
  { onText :: Text -> IO ()
  , onCount :: Int -> IO ()
  , onError :: Text -> IO ()
  , onNote :: Text -> IO ()
  -- ^ something worth saying about how the answer was obtained, printed
  -- after it, because the spinner owns the line until the first words
  }

-- | Send the history to the participant's server and stream the answer.
send :: Client -> Participant -> [Turn] -> Handlers -> IO (Either Text ())
send client p msgs h = case p.row.backend of
  "llamacpp" -> stream "/v1/chat/completions" openAI openAILine
  "hailo" -> do
    useChat <- readIORef p.hailoChat
    if useChat
      then do
        r <- stream "/api/chat" ollamaChat ollamaChatLine
        case r of
          Left e | "HTTP 404" `T.isInfixOf` e || "HTTP 500" `T.isInfixOf` e -> do
            writeIORef p.hailoChat False
            h.onNote "this server has no chat route, so the conversation goes to it as a transcript"
            stream "/api/generate" transcript generateLine
          other -> pure other
      else stream "/api/generate" transcript generateLine
  _ -> stream "/api/chat" ollamaChat ollamaChatLine
  where
    stream path body onLine = do
      r <- postLines client NoAuth p.url path body onLine
      pure case r of
        Left (Status code b) -> Left ("HTTP " <> T.pack (show code) <> ": " <> T.take 160 (T.pack (show b)))
        Left f -> Left (describeFailure f)
        Right () -> Right ()
    messages = [object ["role" .= t.role, "content" .= t.content] | t <- msgs]
    ollamaChat =
      object
        [ "model" .= p.row.model
        , "messages" .= messages
        , "stream" .= True
        , "options"
            .= object
              ( ["num_predict" .= replyBudget]
                  <> ["num_ctx" .= min 16384 (fromMaybe 16384 p.row.window) | p.row.backend == "cpu"]
              )
        ]
    openAI =
      object
        [ "messages" .= messages
        , "stream" .= True
        , "max_tokens" .= replyBudget
        , "cache_prompt" .= True
        ]
    transcript =
      object
        [ "model" .= p.row.model
        , "prompt"
            .= ( T.intercalate "\n\n" [(if t.role == "user" then "User: " else "Assistant: ") <> t.content | t <- msgs]
                   <> "\n\nAssistant:"
               )
        , "stream" .= True
        , "options" .= object ["num_predict" .= replyBudget]
        ]
    withJson raw k = case decodeStrict (fromMaybe raw (B.stripPrefix "data: " raw)) of
      Just (Object o) -> case KeyMap.lookup "error" o of
        Just (String e) -> h.onError e
        Just e -> h.onError (T.pack (show e))
        Nothing -> k o
      _ -> pure ()
    ollamaChatLine raw = withJson raw \o -> do
      forM_ (textAt ["message", "content"] (Object o)) h.onText
      when (KeyMap.lookup "done" o == Just (Bool True)) $
        forM_ (intAt ["eval_count"] (Object o)) h.onCount
    generateLine raw = withJson raw \o -> do
      forM_ (textAt ["response"] (Object o)) h.onText
      when (KeyMap.lookup "done" o == Just (Bool True)) $
        forM_ (intAt ["eval_count"] (Object o)) h.onCount
    openAILine raw
      | B.isPrefixOf "data: [DONE]" raw = pure ()
      | otherwise = withJson raw \o -> do
          case KeyMap.lookup "choices" o of
            Just (Array cs) | (c : _) <- foldr (:) [] cs -> forM_ (textAt ["delta", "content"] c) h.onText
            _ -> pure ()
          forM_ (intAt ["timings", "predicted_n"] (Object o)) h.onCount

-- | A spinner with the seconds elapsed, until the first words. The first
-- request to a model that is not in memory includes loading it, which on
-- oracle is up to a minute for an 8B.
spinner :: UTCTime -> MVar UTCTime -> IO ()
spinner started done = go (0 :: Int)
  where
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: String
    go i = do
      finished <- isJust <$> tryReadMVar done
      unless finished do
        now <- getCurrentTime
        let s = round (realToFrac (diffUTCTime now started) :: Double) :: Int
        TIO.putStr ("\r\ESC[2K  " <> fg cAccent (T.singleton (frames !! (i `mod` length frames))) <> fg cGrey (" thinking  " <> T.pack (show s) <> " s"))
        hFlush stdout
        threadDelay 120000
        go (i + 1)

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
