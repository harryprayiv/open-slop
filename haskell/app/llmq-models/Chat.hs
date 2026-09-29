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
-- LLAMA-SERVER STARTS AND STOPS BY ITSELF
-- ============================================================================
--
-- llama-server is not resident by default: it holds its whole model, about
-- 5.5 GB for the 7B, for as long as it runs, so oracle starts it only when
-- asked. The chat does the asking, so nobody has to know that:
--
--   opening a chat with its model   starts it at once if it is not already
--                                   answering. The request takes a second;
--                                   loading the model takes about a minute,
--                                   during which the status line says it is
--                                   loading and the user can already type.
--   a message to it                 waits until it answers /health with ok,
--                                   counting the seconds on the input line,
--                                   and starts it again first if it has gone
--                                   down since.
--   leaving the chat                stops it, if and only if this chat
--                                   started it. A server started any other
--                                   way is left running for whoever did.
--
-- Starting and stopping is `sudo -n systemctl start|stop
-- llama-server.service` on the server's host, over ssh as the current user.
-- /start and /stop do the same by hand and remain for when that is wanted.
--
-- sudo -n never prompts: it succeeds only through the passwordless rule the
-- host grants for exactly these commands (services.open-slop.llamaServer
-- .controlledBy), and otherwise fails at once with sudo's own message, which
-- is shown. ssh runs in batch mode for the same reason: a missing key is an
-- error on screen, not a password prompt hidden behind the chat.
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
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Live (Live (..))
import Models
import OpenSlop.Http (Auth (..), Client, HttpFailure (..), describeFailure, getBody, postLines)
import Render (statusLine)
import Style
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.Process (proc, readCreateProcessWithExitCode)

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
  startedHere <- newIORef False
  -- Start llama-server now if this chat needs it, so the model loads while
  -- the first message is being typed.
  forM_ (find (\p -> p.row.backend == "llamacpp") ps) \p -> do
    up <- healthy p
    unless up do
      setBottom scr (fg cGrey ("  asking " <> hostOf p.url <> " to start llama-server...")) keys
      r <- serverControl p "start"
      case r of
        Right () -> do
          writeIORef startedHere True
          block scr cCyan (fg cCyan (bold ("starting llama-server on " <> hostOf p.url)))
          stream scr cMuted "it runs only while something uses it. Loading the model takes about a minute; the status line above shows it loading, and a message sent before it is ready waits for it. Leaving this chat stops it again."
          endBlock scr
        Left e -> do
          block scr cRed (fg cRed (bold "llama-server could not be started"))
          stream scr cRed e
          endBlock scr
  converse scr keys file (ensureUp scr keys startedHere) ps
  -- Leave llama-server as it was found: stopped, if this chat started it.
  mine <- readIORef startedHere
  when mine $
    forM_ (find (\p -> p.row.backend == "llamacpp") ps) \p -> do
      setBottom scr (fg cGrey "  stopping llama-server, which this chat started...") keys
      _ <- serverControl p "stop"
      pure ()
  killThread bars
  closeScreen scr

-- | Make sure the participant's server is answering before a message goes
-- to it. Only llama-server can be down by design; for it, start it if it
-- is not running and wait until it answers /health with ok. False when it
-- could not be brought up, with the reason already on screen.
ensureUp :: Screen -> Text -> IORef Bool -> Participant -> IO Bool
ensureUp scr keys startedHere p
  | p.row.backend /= "llamacpp" = pure True
  | otherwise = do
      up <- healthy p
      if up
        then pure True
        else do
          -- Refused outright means the service is stopped, not loading.
          refused <- isRefused p
          started <-
            if refused
              then do
                setBottom scr (fg cGrey ("  asking " <> hostOf p.url <> " to start llama-server...")) keys
                r <- serverControl p "start"
                case r of
                  Right () -> writeIORef startedHere True >> pure True
                  Left e -> do
                    note scr (fg cRed ("llama-server could not be started: " <> e))
                    pure False
              else pure True
          if not started
            then pure False
            else do
              t0 <- getCurrentTime
              ok <- waitHealthy scr keys p t0
              unless ok $
                note scr (fg cRed "llama-server did not come up within four minutes; its log on the host says why: journalctl -u llama-server")
              pure ok

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

converse :: Screen -> Text -> FilePath -> (Participant -> IO Bool) -> [Participant] -> IO ()
converse scr keys file ensure ps = do
  input <- readInput scr (fg cAccent (bold " you ❯ ")) keys
  case T.strip <$> input of
    Nothing -> pure ()
    Just q
      | q `elem` ["/back", "/b", "/q", "/quit"] -> pure ()
      | q == "/start" || q == "/stop" -> do
          case find (\p -> p.row.backend == "llamacpp") ps of
            Nothing -> do
              block scr cMuted (fg cGrey "no model in this chat is served by llama-server")
              endBlock scr
            Just p -> control scr keys p (T.drop 1 q)
          converse scr keys file ensure ps
      | q == "/clear" -> do
          forM_ ps \p -> writeIORef p.history []
          block scr cMuted (fg cGrey "started over: every model has forgotten the conversation")
          endBlock scr
          record file "\n---\n\n*started over*\n"
          converse scr keys file ensure ps
      | T.null q -> converse scr keys file ensure ps
      | otherwise -> do
          block scr cAccent (fg cAccent (bold "you"))
          stream scr cText q
          endBlock scr
          record file ("\n**you**\n\n" <> q <> "\n")
          forM_ ps \p -> turn scr keys file ensure p q
          converse scr keys file ensure ps

-- | One user message to one participant, and its streamed answer.
turn :: Screen -> Text -> FilePath -> (Participant -> IO Bool) -> Participant -> Text -> IO ()
turn scr keys file ensure p q = do
  let name = p.row.backend <> "/" <> p.row.model
  block scr p.colour (fg p.colour (bold ("● " <> name)))
  up <- ensure p
  if up then answerTurn scr keys file p q else record file ("\n**" <> name <> "**: no answer: the server could not be started\n")

-- | The part of a turn after the server is known to be answering.
answerTurn :: Screen -> Text -> FilePath -> Participant -> Text -> IO ()
answerTurn scr keys file p q = do
  modifyIORef' p.history (<> [Turn "user" q])
  dropped <- fitWindow p
  let name = p.row.backend <> "/" <> p.row.model
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
    (Right (Left e), _) | p.row.backend == "llamacpp" && "refused" `T.isInfixOf` e -> do
      note scr (fg cRed "no answer: llama-server stopped while this message was being sent. " <> fg cGrey "the next message starts it again")
      record file ("\n**" <> name <> "**: no answer: llama-server is not running\n")
      modifyIORef' p.history (take (length msgs - 1))
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

-- | The host part of an endpoint URL: "http://192.168.8.173:8081" gives
-- "192.168.8.173".
hostOf :: Text -> Text
hostOf u = T.takeWhile (/= ':') (fromMaybe u (T.stripPrefix "http://" u))

-- | Run `sudo -n systemctl VERB llama-server.service` on the participant's
-- host. Left carries ssh's or sudo's own message.
--
-- sudo -n never prompts: it succeeds only through the passwordless rule the
-- host grants for exactly these commands (services.open-slop.llamaServer
-- .controlledBy). ssh runs in batch mode for the same reason: a missing key
-- is an error on screen, not a password prompt hidden behind the chat.
serverControl :: Participant -> Text -> IO (Either Text ())
serverControl p verb = do
  (code, _, err) <-
    readCreateProcessWithExitCode
      (proc "ssh" ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", T.unpack (hostOf p.url), "sudo", "-n", "systemctl", T.unpack verb, "llama-server.service"])
      ""
  pure case code of
    ExitSuccess -> Right ()
    ExitFailure n -> Left ("ssh or sudo refused (exit " <> T.pack (show n) <> "): " <> T.strip (T.pack err))

-- | Whether the server answers /health with ok right now.
healthy :: Participant -> IO Bool
healthy p = do
  r <- getBody p.client NoAuth (p.url <> "/health") 3
  pure case r of
    Right b -> "\"ok\"" `B.isInfixOf` BL.toStrict b
    Left _ -> False

-- | Whether nothing is listening at all, as opposed to a server that is up
-- and still loading its model.
isRefused :: Participant -> IO Bool
isRefused p = do
  r <- getBody p.client NoAuth (p.url <> "/health") 3
  pure case r of
    Left (Status _ _) -> False
    Left _ -> True
    Right _ -> False

-- | Wait until the server answers /health with ok, counting on the input
-- line. Four minutes is several times the 7B's load time on oracle.
waitHealthy :: Screen -> Text -> Participant -> UTCTime -> IO Bool
waitHealthy scr keys p started = do
  r <- getBody p.client NoAuth (p.url <> "/health") 3
  now <- getCurrentTime
  let secs = realToFrac (diffUTCTime now started) :: Double
      state = case r of
        Right b | "\"ok\"" `B.isInfixOf` BL.toStrict b -> Nothing
        Right _ -> Just "loading the model"
        Left (Status _ _) -> Just "loading the model"
        Left _ -> Just "starting"
  case state of
    Nothing -> pure True
    Just what
      | secs > 240 -> pure False
      | otherwise -> do
          setBottom
            scr
            (" " <> fg cCyan "◌ llama-server " <> fg cGrey (what <> "  " <> T.pack (show (round secs :: Int)) <> " s") <> fg cMuted "   about a minute for the 7B; your message goes as soon as it is ready")
            keys
          threadDelay 2000000
          waitHealthy scr keys p started

-- | /start and /stop by hand: the same actions as the automatic ones, with
-- their outcome written into the conversation.
control :: Screen -> Text -> Participant -> Text -> IO ()
control scr keys p verb = do
  block scr cCyan (fg cCyan (bold ((if verb == "start" then "starting" else "stopping") <> " llama-server on " <> hostOf p.url)))
  setBottom scr (fg cGrey ("  asking " <> hostOf p.url <> " over ssh...")) keys
  r <- serverControl p verb
  case r of
    Left e -> stream scr cRed e >> endBlock scr
    Right ()
      | verb == "stop" -> stream scr cGreen "stopped; its memory is free" >> endBlock scr
      | otherwise -> do
          t0 <- getCurrentTime
          ok <- waitHealthy scr keys p t0
          now <- getCurrentTime
          let s = duration (realToFrac (diffUTCTime now t0))
          if ok
            then stream scr cGreen ("ready after " <> s)
            else stream scr cRed ("still not answering after " <> s <> "; its log on the host says why: journalctl -u llama-server")
          endBlock scr

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