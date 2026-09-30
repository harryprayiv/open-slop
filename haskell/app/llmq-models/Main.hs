-- | llmq-models: the measured catalogue as a table and a graph, and a chat
-- with any model on it, or with several at once to compare them.
--
-- Reads the catalogue llmq reads ($OPEN_SLOP_CATALOGUE, or --catalogue)
-- with the measurements in this machine's cache laid over it, through the
-- same loader llmq uses (OpenSlop.Measured), so it shows exactly the numbers
-- llmq budgets from.
--
--   llmq-models                    plain table, fastest decode first
--   llmq-models --sort prefill     sorted by another column
--   llmq-models --tui              interactive
--
-- ============================================================================
-- THE INTERACTIVE VIEW
-- ============================================================================
--
-- One selection, three screens. The table lists every model on one line;
-- the selected model's specs, what an answer will cost, and how it did on
-- the restraint probes appear in a panel under it and nowhere else. The
-- graph plots every model by parameter count against speed. The answers
-- page shows what the model actually said to each restraint probe. Keys:
--
--   j k, arrows   move              enter, a   chat with the model
--   m             mark for compare  c          clear the marks
--   v             table or graph    p          its restraint answers
--   y             graph axis        s, r       sort column, reverse
--   b             what to measure   q          quit
--
-- Enter with models marked opens one chat with all of them: every message
-- goes to each marked model in turn, and each answers from its own
-- history. With nothing marked it chats with the selected model alone.
--
-- ============================================================================
-- CHATTING, AND KNOWING IT IS WORKING
-- ============================================================================
--
-- A real conversation: each model keeps its history and every turn is sent
-- to its server's chat endpoint (see Chat). Until the first words arrive a
-- spinner shows the seconds elapsed, which on a model that is not in memory
-- includes loading it; then the answer streams; then the time, the wait for
-- the first words, and the rate.
--
-- ============================================================================
-- WHERE THE NUMBERS COME FROM
-- ============================================================================
--
-- All from llmq-bench, whose header says how each is measured:
--
--   decode     tok/s generating, and the reading-speed band it falls in:
--              5 and up keeps pace with a reader (conversational), 2 to 5
--              makes you wait a little (readable), under 2 is start it and
--              come back (batch)
--   prefill    tok/s reading a prompt
--   load       seconds to bring the model into memory before it can answer
--   params     the server's exact parameter count where it reports one;
--              otherwise read from the model's name and shown with a ~
--   restraint  how many of seven edgy-but-legitimate requests it refused.
--              The political-opinion probe is shown on its own and not
--              counted: declining to pick a party for someone is a
--              reasonable answer, not stiffness.
--
-- ============================================================================
-- NOTICING WHAT NEEDS MEASURING
-- ============================================================================
--
-- In the background, at start and every ten minutes, the servers are asked
-- what they serve and each model is checked against the measurements file
-- (OpenSlop.Measured.pending): a model never measured, one whose served
-- weights changed, one whose last run had problems or no restraint results,
-- or one measured over thirty days ago. When any exist, a line under the
-- status line says how many and names them, and `b` shows each with its
-- reason and the commands that measure them. Nothing here starts a
-- measurement; that is llmq-bench, run by hand, overnight. The file is
-- re-read each time, so the line goes away once a run has covered them.
--
-- ============================================================================
-- THE MODULES
-- ============================================================================
--
--   Models      the catalogue read into rows, and sorting
--   Style       colours, width-aware text, terminal control
--   Render      the table, panel, graph and answers screens
--   Chat        conversations with one model or several at once
--   ChatScreen  the chat's screen: fixed bars, scrolling conversation, input
--   Live        what oracle is doing right now, fetched in the background
--   Main        options and the interactive loop
module Main (main) where

import Chat (chatWith)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, swapMVar)
import Control.Exception (finally)
import Control.Monad (forM_, forever, unless, void)
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime, utctDay)
import Live
import Models
import OpenSlop.Catalogue (Catalogue)
import OpenSlop.Http (Client, newClient)
import OpenSlop.Measured (Pending (..), defaultPolicy, loadCatalogueValue, measuredPath, pending, readMeasured)
import Render
import Style
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO

data Opts = Opts
  { catalogueFile :: Maybe FilePath
  , sortKey :: SortKey
  , interactive :: Bool
  }

parseOpts :: [String] -> Either String Opts
parseOpts = go (Opts Nothing ByDecode False)
  where
    go o [] = Right o
    go o ("--tui" : rest) = go o {interactive = True} rest
    go o ("--catalogue" : f : rest) = go o {catalogueFile = Just f} rest
    go o ("--sort" : s : rest) = case [k | k <- [minBound .. maxBound], T.unpack (sortName k) == s] of
      (k : _) -> go o {sortKey = k} rest
      [] -> Left ("unknown sort column " <> s <> "; use decode, prefill, load, params, restraint or name")
    go _ (a : _) = Left ("unknown argument " <> a <> "\nusage: llmq-models [--sort decode|prefill|load|params|restraint|name] [--tui] [--catalogue FILE]")

main :: IO ()
main = do
  hSetEncoding stdout utf8
  args <- getArgs
  opts <- either die' pure (parseOpts args)
  path <- case opts.catalogueFile of
    Just p -> pure p
    Nothing -> lookupEnv "OPEN_SLOP_CATALOGUE" >>= maybe (die' "no catalogue: pass --catalogue or set OPEN_SLOP_CATALOGUE") pure
  (doc, notes) <- loadCatalogueValue path >>= either die' pure
  cat <- case Aeson.fromJSON doc :: Aeson.Result Catalogue of
    Aeson.Success c -> pure c
    Aeson.Error e -> die' (path <> ": " <> e)
  let rows = rowsOf doc
  client <- newClient
  if opts.interactive
    then do
      -- The machine is asked in the background every three seconds, so a
      -- slow or unreachable row never holds up a keypress.
      liveVar <- newMVar emptyLive
      let eps = endpointsOf doc
      void $ forkIO $ forever do
        l <- fetchLive client eps
        void (swapMVar liveVar l)
        threadDelay 3000000
      pendingVar <- newMVar []
      void $ forkIO $ forever do
        ps <- pendingNow client cat
        void (swapMVar pendingVar ps)
        threadDelay 600000000
      runTui (Env liveVar pendingVar client eps) rows opts.sortKey
    else do
      forM_ notes \n -> TIO.hPutStrLn stderr ("llmq-models: " <> n)
      mapM_ TIO.putStrLn (tableLines (const False) (const False) 120 (sortRows opts.sortKey False rows) Nothing)
      ps <- pendingNow client cat
      unless (null ps) do
        TIO.hPutStrLn stderr ""
        mapM_ (TIO.hPutStrLn stderr) (pendingText ps)

-- | What the servers serve that the measurements file says needs measuring.
-- The file is read fresh each time. An unreadable file offers nothing: the
-- loader has already said why it was not used.
pendingNow :: Client -> Catalogue -> IO [Pending]
pendingNow client cat = do
  today <- utctDay <$> getCurrentTime
  measured <- measuredPath >>= readMeasured
  case measured of
    Left _ -> pure []
    Right m -> pending client cat m defaultPolicy today

-- | The offer in full: each model with its reason, and how to measure them.
pendingText :: [Pending] -> [Text]
pendingText ps =
  [T.pack (show (length ps)) <> " served " <> (if length ps == 1 then "model needs" else "models need") <> " measuring:", ""]
    <> ["  " <> p.endpoint <> "/" <> p.model <> "   " <> p.reason | p <- ps]
    <> [ ""
       , "Nothing is measured until you run it. One command covers every backend unattended,"
       , "overnight, where USER@HOST may switch llama-server and drop the page cache on the row."
       , "Check that first:"
       , ""
       , "  llmq-bench --preflight --control USER@HOST"
       , ""
       , "then start it:"
       , ""
       , "  systemd-run --user --unit=llmq-bench-night --setenv=SSH_AUTH_SOCK=\"$SSH_AUTH_SOCK\" \"$(command -v llmq-bench)\" --control USER@HOST"
       , ""
       , "Results go to the measurements file in this machine's cache after each model; the"
       , "next llmq-models started shows them."
       ]

-- | What the interactive screens share: the latest picture of the row, and
-- the client and endpoints a chat talks through.
data Env = Env
  { liveVar :: MVar Live
  , pendingVar :: MVar [Pending]
  , client :: Client
  , eps :: [(Text, Text)]
  }


data View = TableView | GraphView | AnswersView | PendingView
  deriving stock (Eq)

data Tui = Tui
  { rows :: [Row]
  , key :: SortKey
  , reversed :: Bool
  , cursor :: Int
  , view :: View
  , metric :: Metric
  , marked :: [(Text, Text)]
  -- ^ (backend, model) of each model marked for a comparison chat
  }

isMarked :: Tui -> Row -> Bool
isMarked st r = (r.backend, r.model) `elem` st.marked

runTui :: Env -> [Row] -> SortKey -> IO ()
runTui env rs k = do
  oldBuf <- hGetBuffering stdin
  oldEcho <- hGetEcho stdin
  enterScreen
  loop env (Tui rs k False 0 TableView MDecode [])
    `finally` do
      leaveScreen
      hSetBuffering stdin oldBuf
      hSetEcho stdin oldEcho

-- | Each segment carries its own background, because the selected tab's
-- colour ends with a background reset that would otherwise strip the bar's
-- colour from everything after it.
titleBar :: Int -> Tui -> Int -> Text
titleBar width st n =
  let bar t = bg cBar (fg cText t)
      left = bar (bold " open-slop" <> "  models on oracle   ")
      tabs = T.concat [tab v l | (v, l) <- [(TableView, "table"), (GraphView, "graph"), (AnswersView, "answers")]]
      right = bar (T.pack (show n) <> " models   sort " <> sortName st.key <> (if st.reversed then " ↑ " else " ↓ "))
      tab v l = if st.view == v then bg cAccent (fg 16 (bold (" " <> l <> " "))) else bar (" " <> l <> " ")
      middle = width - visibleLength left - visibleLength tabs - visibleLength right
   in clip width (left <> tabs <> bar (T.replicate (max 1 middle) " ") <> right)

keyBar :: Int -> Text
keyBar width =
  clip width (bg cPanel (padTo width (T.concat [" " <> bg cSel (fg cText (" " <> k <> " ")) <> fg cGrey (" " <> d) | (k, d) <- keys])))
  where
    keys = [("enter", "chat"), ("m", "compare"), ("v", "view"), ("p", "answers"), ("b", "to measure"), ("y", "axis"), ("s", "sort"), ("r", "reverse"), ("q", "quit")]

-- | One line naming what needs measuring, shown only when something does.
offerLine :: Int -> [Pending] -> Text
offerLine width ps =
  clip width . bg cPanel . padTo width $
    fg cAccent (bold (" " <> T.pack (show (length ps)) <> " to measure "))
      <> fg cText (T.intercalate ", " [p.model | p <- ps])
      <> fg cMuted "   b: why, and the command"

-- | Draw, then wait up to a second for a key. With no key the screen is
-- drawn again, which is how the status line stays current.
loop :: Env -> Tui -> IO ()
loop env st = do
  (height0, width) <- termSize
  live <- readMVar env.liveVar
  toMeasure <- readMVar env.pendingVar
  now <- getCurrentTime
  let offer = [offerLine width toMeasure | not (null toMeasure)]
      height = height0 - length offer
      sorted = sortRows st.key st.reversed st.rows
      n = length sorted
      cur = max 0 (min (n - 1) st.cursor)
      selectedRow = listToMaybe (drop cur sorted)
      body = case st.view of
        TableView ->
          let panelLines = maybe [] (\r -> panel (resident live r) width r) selectedRow
              room = max 1 (height - 5 - length panelLines)
              top = max 0 (cur - room + 1)
           in tableLines (resident live) (isMarked st) width (take room (drop top sorted)) (Just (cur - top)) <> [""] <> panelLines
        GraphView -> graphLines width (height - 1) st.metric sorted cur
        AnswersView -> case selectedRow of
          Just r -> (bold (fg cText (r.backend <> "/" <> r.model)) <> fg cMuted "   the opening of each answer, as the bench stored it") : "" : answersLines width r
          Nothing -> []
        PendingView
          | null toMeasure -> [fg cText "Every served model has a current measurement."]
          | otherwise -> map (fg cText) (pendingText toMeasure)
  -- Redrawn in place, line by line, each cleared to its end, rather than
  -- clearing the whole screen first: the screen now redraws every second
  -- for the status line, and a full clear flickers.
  TIO.putStr "\ESC[H"
  mapM_
    (\l -> TIO.putStr (l <> "\ESC[K\n"))
    ( titleBar width st n
        : statusLine now width live
        : offer
          <> map (clip width) (take (height - 3) body)
    )
  TIO.putStr "\ESC[J"
  TIO.putStr ("\ESC[" <> T.pack (show height0) <> ";1H" <> keyBar width)
  hFlush stdout
  pressed <- hWaitForInput stdin 1000
  k <- if pressed then readKey else pure KNone
  let st' = st {cursor = cur}
      loop' = loop env
  case k of
    KQuit -> if st.view `elem` [AnswersView, PendingView] then loop' st' {view = TableView} else pure ()
    KNone -> loop' st'
    KDown -> loop' st' {cursor = min (n - 1) (cur + 1)}
    KUp -> loop' st' {cursor = max 0 (cur - 1)}
    KTop -> loop' st' {cursor = 0}
    KBottom -> loop' st' {cursor = n - 1}
    KSort -> loop' st' {key = if st.key == maxBound then minBound else succ st.key, cursor = 0}
    KReverse -> loop' st' {reversed = not st.reversed, cursor = 0}
    KView -> loop' st' {view = if st.view == TableView then GraphView else TableView}
    KAnswers -> loop' st' {view = if st.view == AnswersView then TableView else AnswersView}
    KAxis -> loop' st' {metric = if st.metric == MDecode then MPrefill else MDecode}
    KPending -> loop' st' {view = if st.view == PendingView then TableView else PendingView}
    KMark -> case selectedRow of
      Just r ->
        let k' = (r.backend, r.model)
         in loop' st' {marked = if k' `elem` st.marked then filter (/= k') st.marked else st.marked <> [k']}
      Nothing -> loop' st'
    KClearMarks -> loop' st' {marked = []}
    KAsk -> do
      let chosen = if null st.marked then maybe [] pure selectedRow else [r | r <- st.rows, isMarked st r]
          withUrl = [(r, u) | r <- chosen, Just u <- [lookup r.backend env.eps]]
      if null withUrl then pure () else chatWith env.client env.liveVar withUrl
      loop' st'
    KOther -> loop' st'

data Key = KUp | KDown | KTop | KBottom | KSort | KReverse | KView | KAnswers | KAxis | KPending | KAsk | KMark | KClearMarks | KQuit | KNone | KOther

readKey :: IO Key
readKey = do
  c <- getChar
  case c of
    'q' -> pure KQuit
    'j' -> pure KDown
    'k' -> pure KUp
    'g' -> pure KTop
    'G' -> pure KBottom
    's' -> pure KSort
    'r' -> pure KReverse
    'v' -> pure KView
    'p' -> pure KAnswers
    'y' -> pure KAxis
    'b' -> pure KPending
    '\n' -> pure KAsk
    'a' -> pure KAsk
    'm' -> pure KMark
    'c' -> pure KClearMarks
    '\ESC' -> do
      more <- hWaitForInput stdin 30
      if not more
        then pure KQuit
        else do
          _ <- getChar
          d <- getChar
          pure case d of
            'A' -> KUp
            'B' -> KDown
            _ -> KOther
    _ -> pure KOther


die' :: String -> IO a
die' msg = hPutStrLn stderr ("llmq-models: " <> msg) >> exitFailure