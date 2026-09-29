-- | Chatting with one model, or with several at once to compare them.
--
-- Part of llmq-models; Main describes the program, ChatScreen the screen.
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
-- slow each other down and, at 8B, may not both fit in memory. Comparing
-- two large CPU models can make ollama unload one to load the other on
-- every turn, which shows as a long wait for the first words. A CPU model
-- against an NPU model runs on separate hardware and has no such cost.
--
-- Each participant gets its own colour, used for its name, the bar beside
-- its answers and its chip in the title bar, so two models on the same
-- backend are still told apart at a glance.
--
-- ============================================================================
-- STOPPING, LEAVING, SCROLLING, AND KEEPING THE CONVERSATION
-- ============================================================================
--
-- Ctrl-C while a model is answering stops that answer: the request is
-- dropped, which makes ollama and llama-server stop generating, and the
-- partial answer stays in the history marked as stopped. Esc, Ctrl-D or
-- Ctrl-C at the input line returns to the model table.
--
-- The whole conversation stays scrollable while the chat is open, including
-- while a model is answering; ChatScreen describes the keys.
--
-- Every conversation is written as it happens to
-- $XDG_STATE_HOME/open-slop/chats/<start time>.md (~/.local/state when that
-- is unset), one paragraph per message and no hard wrapping, so a
-- comparison can be read again after the screen is gone. The key bar shows
-- the file's name.
--
-- ============================================================================
-- STAYING INSIDE THE WINDOW
-- ============================================================================
--
-- A history outgrows a model's window, the NPU's 2,048 tokens soonest. Before
-- each turn the oldest messages are dropped until the history fits the
-- window less the reply budget, estimated with the backend's bytes per token,
-- and the screen says how many were dropped. Without that, ollama and
-- hailo-ollama would silently lose the front of the prompt instead.
module Chat (chatWith) where

import ChatScreen
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (AsyncException (..), throwIO, try)
import Control.Monad (forM_, forever, unless, when)
import Data.Aeson (Value (..), decodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as B
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Live (Live)
import Models
import OpenSlop.Http (Auth (..), Client, HttpFailure (..), describeFailure, postLines)
import Render (statusLine)
import Style
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))

data Turn = Turn
  { role :: Text
  , content :: Text
  }

data Participant = Participant
  { row :: Row
  , client :: Client
  , url :: Text
  , colour :: Int
  , history :: IORef [Turn]
  , hailoChat :: IORef Bool
  -- ^ whether hailo-ollama's /api/chat works; False after one refusal
  }

-- | One colour per participant, in the order they were marked, chosen to be
-- distinct from each other and from the user's accent.
participantColours :: [Int]
participantColours = [215, 213, 80, 150, 75]

-- | Output tokens asked for per reply. Enough for a real answer; small
-- enough that a runaway model on a 2 tok/s backend stops within minutes.
replyBudget :: Int
replyBudget = 512

-- | Chat with the given models, each with the URL of its server, until the
-- user leaves. Returns with the terminal as the model table left it.
chatWith :: Client -> MVar Live -> [(Row, Text)] -> IO ()
chatWith client liveVar targets = do
  ps <- mapM (\((r, u), c) -> Participant r client u c <$> newIORef [] <*> newIORef True) (zip targets (cycle participantColours))
  (h, w) <- termSize
  scr <- openScreen h w
  file <- transcriptFile
  record file ("# " <> T.intercalate " vs " [p.row.backend <> "/" <> p.row.model | p <- ps] <> "\n")
  -- The title and status bars, kept current once a second like the table's.
  bars <- forkIO $ forever do
    now <- getCurrentTime
    live <- readMVar liveVar
    drawTop scr [title w ps, statusLine now w live]
    threadDelay 1000000
  block scr cMuted (fg cGrey (if length ps > 1 then "each message goes to every model above, one after another" else "a conversation; the model sees everything said so far"))
  stream scr cMuted "esc returns to the models; ctrl-c stops an answer; pgup, pgdn, the arrows and the mouse wheel scroll, even while a model answers; end catches up; hold shift to select text with the mouse; /clear starts over"
  endBlock scr
  let keys = keyBar w [("enter", "send"), ("esc", "back to models"), ("ctrl-c", "stop answer"), ("pgup", "scroll back"), ("/clear", "start over")] (T.pack (takeFileName file))
  converse scr keys file ps
  killThread bars
  closeScreen scr

title :: Int -> [Participant] -> Text
title w ps =
  let bar t = bg cBar (fg cText t)
      chip p = bg p.colour (fg 16 (bold (" " <> p.row.backend <> "/" <> p.row.model <> " ")))
      left = bar (bold " open-slop" <> "  " <> (if length ps > 1 then "compare" else "chat") <> "   ")
      chips = T.intercalate (bar " vs ") (map chip ps)
   in clip w (left <> chips <> bar (T.replicate (max 1 (w - visibleLength left - visibleLength chips)) " "))

keyBar :: Int -> [(Text, Text)] -> Text -> Text
keyBar w keys file =
  let left = T.concat [" " <> bg cSel (fg cText (" " <> k <> " ")) <> fg cGrey (" " <> d) | (k, d) <- keys]
      right = fg cMuted ("chats/" <> file <> " ")
   in clip w (left <> T.replicate (max 1 (w - visibleLength left - visibleLength right)) " " <> right)

converse :: Screen -> Text -> FilePath -> [Participant] -> IO ()
converse scr keys file ps = do
  input <- readInput scr (fg cAccent (bold " you ❯ ")) keys
  case T.strip <$> input of
    Nothing -> pure ()
    Just q
      | q `elem` ["/back", "/b", "/q", "/quit"] -> pure ()
      | q == "/clear" -> do
          forM_ ps \p -> writeIORef p.history []
          block scr cMuted (fg cGrey "started over: every model has forgotten the conversation")
          endBlock scr
          record file "\n---\n\n*started over*\n"
          converse scr keys file ps
      | T.null q -> converse scr keys file ps
      | otherwise -> do
          block scr cAccent (fg cAccent (bold "you"))
          stream scr cText q
          endBlock scr
          record file ("\n**you**\n\n" <> q <> "\n")
          forM_ ps \p -> turn scr keys file p q
          converse scr keys file ps

-- | One user message to one participant, and its streamed answer.
turn :: Screen -> Text -> FilePath -> Participant -> Text -> IO ()
turn scr keys file p q = do
  modifyIORef' p.history (<> [Turn "user" q])
  dropped <- fitWindow p
  let name = p.row.backend <> "/" <> p.row.model
  block scr p.colour (fg p.colour (bold ("● " <> name)))
  when (dropped > 0) $ do
    stream scr cMuted ("(dropped the oldest " <> T.pack (show dropped) <> " messages to fit the window)")
    note scr ""
  msgs <- readIORef p.history
  started <- getCurrentTime
  firstAt <- newIORef (Nothing :: Maybe UTCTime)
  answer <- newIORef ("" :: Text)
  tokens <- newIORef (0 :: Int)
  reported <- newIORef (Nothing :: Maybe Int)
  failure <- newIORef (Nothing :: Maybe Text)
  notes <- newMVar ([] :: [Text])
  indicator <- forkIO (thinking scr keys p started firstAt)
  let onText t = unless (T.null t) do
        seen <- readIORef firstAt
        when (seen == Nothing) (getCurrentTime >>= writeIORef firstAt . Just)
        stream scr cText t
        modifyIORef' answer (<> t)
        modifyIORef' tokens (+ 1)
      handlers =
        Handlers
          onText
          (writeIORef reported . Just)
          (writeIORef failure . Just)
          (\t -> modifyMVar_ notes (pure . (<> [t])))
  result <- try (send p msgs handlers) :: IO (Either AsyncException (Either Text ()))
  killThread indicator
  endBlock scr
  finished <- getCurrentTime
  err <- readIORef failure
  full <- readIORef answer
  pending <- readMVar notes
  first <- readIORef firstAt
  counted <- readIORef tokens
  n <- fromMaybe counted <$> readIORef reported
  let total = secs started finished
      wait = maybe total (secs started) first
      rate = fromIntegral n / max 0.1 (total - wait)
      timing =
        fg cGrey (duration total)
          <> fg cMuted " in all · first words after "
          <> fg cGrey (duration wait)
          <> fg cMuted " · "
          <> fg cGrey (T.pack (show n) <> " tokens")
          <> fg cMuted " · "
          <> fg (rateColour rate) (fmt "%.1f tok/s" rate)
  case (result, err) of
    (Left UserInterrupt, _) -> do
      modifyIORef' p.history (<> [Turn "assistant" (full <> " [stopped]")])
      note scr (fg cYellow "stopped · " <> timing)
      record file ("\n**" <> name <> "** (stopped)\n\n" <> full <> "\n")
    (Left e, _) -> throwIO e
    (Right (Left e), _) -> do
      note scr (fg cRed ("no answer: " <> e))
      record file ("\n**" <> name <> "**: no answer: " <> e <> "\n")
      modifyIORef' p.history (take (length msgs - 1))
    (_, Just e) -> do
      note scr (fg cRed ("server error: " <> e))
      record file ("\n**" <> name <> "**: server error: " <> e <> "\n")
      modifyIORef' p.history (take (length msgs - 1))
    _ -> do
      modifyIORef' p.history (<> [Turn "assistant" full])
      note scr timing
      record file ("\n**" <> name <> "** (" <> duration total <> ", " <> fmt "%.1f tok/s" rate <> ")\n\n" <> T.strip full <> "\n")
  forM_ pending \t -> note scr (fg cMuted t)
  where
    secs a b = realToFrac (diffUTCTime b a) :: Double
    rateColour r
      | r >= 5 = cGreen
      | r >= 2 = cYellow
      | otherwise = cRed

-- | The input row while a model works: who is thinking, for how long, and
-- how to stop it. Once the first words arrive it says the model is
-- answering instead.
thinking :: Screen -> Text -> Participant -> UTCTime -> IORef (Maybe UTCTime) -> IO ()
thinking scr keys p started firstAt = go (0 :: Int)
  where
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: String
    go i = do
      now <- getCurrentTime
      seen <- readIORef firstAt
      let s = round (realToFrac (diffUTCTime now started) :: Double) :: Int
          verb = maybe "thinking" (const "answering") seen
      setBottom
        scr
        ( " "
            <> fg p.colour (T.singleton (frames !! (i `mod` length frames)))
            <> " "
            <> fg p.colour (bold (p.row.backend <> "/" <> p.row.model))
            <> fg cGrey (" " <> verb <> "  " <> T.pack (show s) <> " s")
            <> fg cMuted "   ctrl-c stops it"
        )
        keys
      threadDelay 120000
      go (i + 1)

-- | Where this conversation is written, created if needed.
transcriptFile :: IO FilePath
transcriptFile = do
  base <- lookupEnv "XDG_STATE_HOME" >>= maybe ((</> ".local/state") <$> getHomeDirectory) pure
  let dir = base </> "open-slop" </> "chats"
  createDirectoryIfMissing True dir
  stamp <- formatTime defaultTimeLocale "%Y-%m-%d-%H%M%S" <$> getZonedTime
  pure (dir </> (stamp <> ".md"))

record :: FilePath -> Text -> IO ()
record = TIO.appendFile

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
  -- ^ something worth saying about how the answer was obtained, shown
  -- under it
  }

-- | Send the history to the participant's server and stream the answer.
send :: Participant -> [Turn] -> Handlers -> IO (Either Text ())
send p msgs h = case p.row.backend of
  "llamacpp" -> streamTo "/v1/chat/completions" openAI openAILine
  "hailo" -> do
    useChat <- readIORef p.hailoChat
    if useChat
      then do
        r <- streamTo "/api/chat" ollamaChat ollamaChatLine
        case r of
          Left e | "HTTP 404" `T.isInfixOf` e || "HTTP 500" `T.isInfixOf` e -> do
            writeIORef p.hailoChat False
            h.onNote "this server has no chat route, so the conversation goes to it as a transcript"
            streamTo "/api/generate" transcript generateLine
          other -> pure other
      else streamTo "/api/generate" transcript generateLine
  _ -> streamTo "/api/chat" ollamaChat ollamaChatLine
  where
    streamTo path body onLine = do
      r <- postLines p.client NoAuth p.url path body onLine
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