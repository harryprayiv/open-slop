-- | llmq-models: the measured catalogue as a table, a graph, and a place to
-- ask a model a question.
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
--   j k, arrows   move              enter, a   ask the selected model
--   v             table or graph    p          its restraint answers
--   y             graph axis        s, r       sort column, reverse
--   q             quit
--
-- ============================================================================
-- ASKING, AND KNOWING IT IS WORKING
-- ============================================================================
--
-- The question goes to `llmq ask -m BACKEND/NAME`, the same command you
-- would type, and its output is read here. Before sending, an estimate from
-- this model's measurements: load time if it is not in memory, prompt over
-- its prefill rate, a 200-token answer over its decode rate. Until the
-- first words arrive a spinner shows the seconds elapsed; then the answer
-- streams; then the real time and rate.
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
--   Ask      asking a model, with the estimate and the thinking indicator
--   Live     what oracle is doing right now, fetched in the background
--   Main     options and the interactive loop
module Main (main) where

import Ask (askModel)
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
import OpenSlop.Http (newClient)
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
      runTui liveVar rows opts.sortKey
    else mapM_ TIO.putStrLn (tableLines (const False) 120 (sortRows opts.sortKey False rows) Nothing)


data View = TableView | GraphView | AnswersView
  deriving stock (Eq)

data Tui = Tui
  { rows :: [Row]
  , key :: SortKey
  , reversed :: Bool
  , cursor :: Int
  , view :: View
  , metric :: Metric
  }

runTui :: MVar Live -> [Row] -> SortKey -> IO ()
runTui liveVar rs k = do
  oldBuf <- hGetBuffering stdin
  oldEcho <- hGetEcho stdin
  enterScreen
  loop liveVar (Tui rs k False 0 TableView MDecode)
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
    keys = [("enter", "ask"), ("v", "view"), ("p", "answers"), ("y", "axis"), ("s", "sort"), ("r", "reverse"), ("j k", "move"), ("q", "quit")]

-- | Draw, then wait up to a second for a key. With no key the screen is
-- drawn again, which is how the status line stays current.
loop :: MVar Live -> Tui -> IO ()
loop liveVar st = do
  (height, width) <- termSize
  live <- readMVar liveVar
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
           in tableLines (resident live) width (take room (drop top sorted)) (Just (cur - top)) <> [""] <> panelLines
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
      loop' = loop liveVar
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
    KAsk -> do
      mapM_ askModel selectedRow
      loop' st'
    KOther -> loop' st'

data Key = KUp | KDown | KTop | KBottom | KSort | KReverse | KView | KAnswers | KAxis | KAsk | KQuit | KNone | KOther

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