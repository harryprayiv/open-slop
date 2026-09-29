-- | llmq-models: the measured catalogue as a table and a graph, and a chat
-- with any model on it, or with several at once to compare them.
--
-- Reads the catalogue llmq reads ($OPEN_SLOP_CATALOGUE, or --catalogue), so
-- it shows exactly the numbers llmq budgets from: everything llmq-bench
-- wrote into the consumer's catalogue.extra, merged over open-slop's own
-- entries by Nix.
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
--   q             quit
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
-- THE MODULES
-- ============================================================================
--
--   Models   the catalogue read into rows, and sorting
--   Style    colours, width-aware text, terminal control
--   Render   the table, panel, graph and answers screens
--   Chat     conversations with one model or several at once
--   Live     what oracle is doing right now, fetched in the background
--   Main     options and the interactive loop
module Main (main) where

import Chat (chatWith)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, swapMVar)
import Control.Exception (finally)
import Control.Monad (forever, void)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime)
import Live
import Models
import OpenSlop.Http (Client, newClient)
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
  doc <- eitherDecodeFileStrict path >>= either die' pure
  let rows = rowsOf doc
  if opts.interactive
    then do
      -- The machine is asked in the background every three seconds, so a
      -- slow or unreachable row never holds up a keypress.
      liveVar <- newMVar emptyLive
      client <- newClient
      let eps = endpointsOf doc
      void $ forkIO $ forever do
        l <- fetchLive client eps
        void (swapMVar liveVar l)
        threadDelay 3000000
      runTui (Env liveVar client eps) rows opts.sortKey
    else mapM_ TIO.putStrLn (tableLines (const False) (const False) 120 (sortRows opts.sortKey False rows) Nothing)

-- | What the interactive screens share: the latest picture of the row, and
-- the client and endpoints a chat talks through.
data Env = Env
  { liveVar :: MVar Live
  , client :: Client
  , eps :: [(Text, Text)]
  }


data View = TableView | GraphView | AnswersView
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
    keys = [("enter", "chat"), ("m", "compare"), ("v", "view"), ("p", "answers"), ("y", "axis"), ("s", "sort"), ("r", "reverse"), ("q", "quit")]

-- | Draw, then wait up to a second for a key. With no key the screen is
-- drawn again, which is how the status line stays current.
loop :: Env -> Tui -> IO ()
loop env st = do
  (height, width) <- termSize
  live <- readMVar env.liveVar
  now <- getCurrentTime
  let sorted = sortRows st.key st.reversed st.rows
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
  -- Redrawn in place, line by line, each cleared to its end, rather than
  -- clearing the whole screen first: the screen now redraws every second
  -- for the status line, and a full clear flickers.
  TIO.putStr "\ESC[H"
  mapM_
    (\l -> TIO.putStr (l <> "\ESC[K\n"))
    ( titleBar width st n
        : bg cPanel (padTo width (statusLine now width live))
        : map (clip width) (take (height - 3) body)
    )
  TIO.putStr "\ESC[J"
  TIO.putStr ("\ESC[" <> T.pack (show height) <> ";1H" <> keyBar width)
  hFlush stdout
  pressed <- hWaitForInput stdin 1000
  k <- if pressed then readKey else pure KNone
  let st' = st {cursor = cur}
      loop' = loop env
  case k of
    KQuit -> if st.view == AnswersView then loop' st' {view = TableView} else pure ()
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
    KMark -> case selectedRow of
      Just r ->
        let k' = (r.backend, r.model)
         in loop' st' {marked = if k' `elem` st.marked then filter (/= k') st.marked else st.marked <> [k']}
      Nothing -> loop' st'
    KClearMarks -> loop' st' {marked = []}
    KAsk -> do
      let chosen = if null st.marked then maybe [] pure selectedRow else [r | r <- st.rows, isMarked st r]
          withUrl = [(r, u) | r <- chosen, Just u <- [lookup r.backend env.eps]]
      if null withUrl then pure () else chatWith env.client withUrl
      loop' st'
    KOther -> loop' st'

data Key = KUp | KDown | KTop | KBottom | KSort | KReverse | KView | KAnswers | KAxis | KAsk | KMark | KClearMarks | KQuit | KNone | KOther

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