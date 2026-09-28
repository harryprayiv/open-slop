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
-- Two screens over the same selection. The table lists every model in one
-- line each; the selected model's specs appear in a panel under it and
-- nowhere else. The graph plots every model by parameter count against
-- speed, with the conversational threshold drawn in. Keys:
--
--   j k, arrows     move the selection        enter, a   ask the model
--   v               table or graph            y          graph: decode or prefill
--   s, r            sort column, reverse      q          quit
--
-- ============================================================================
-- ASKING, AND KNOWING IT IS WORKING
-- ============================================================================
--
-- The question goes to `llmq ask -m BACKEND/NAME`, the same command you
-- would type. Its output is read here rather than handed straight to the
-- terminal, so that until the first words arrive there is a spinner, the
-- seconds elapsed, and an estimate from this model's own measurements:
-- prompt tokens over its measured prefill rate until the first words, and a
-- typical answer over its measured decode rate after that. The first request
-- to an ollama model also loads it into memory from the SD card, which no
-- measurement predicts, and the estimate says so. At the end the actual
-- time and an approximate rate are printed.
--
-- ============================================================================
-- WHERE THE NUMBERS COME FROM
-- ============================================================================
--
--   decode    tok/s generating 128 tokens, from llmq-bench
--   prefill   tok/s on the largest cold prompt measured, from llmq-bench
--   warm      seconds for that prompt a second time: the prefix cache
--   window    tokens one request can hold, as the server reports it
--   params    billions of parameters, read from the model's name or its
--             summary ("7b", "Qwen2.5-7B-Instruct"). Shown with a ~ because
--             it is parsed from a name, not measured.
--   feel      decode speed against reading speed. People read about five
--             tokens a second, so 5 and up keeps pace with a reader
--             (conversational), 2 to 5 makes you wait a little (readable),
--             and under 2 is a start-it-and-come-back job (batch).
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, modifyMVar_, putMVar, readMVar, tryReadMVar)
import Control.Exception (SomeException, finally, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeFileStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isDigit, isSpace, toLower)
import Data.List (sortBy)
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.IO
import System.Process
import Text.Printf (printf)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- The data

data Row = Row
  { backend :: Text
  , model :: Text
  , decode :: Maybe Double
  , prefill :: Maybe (Int, Double)
  , warm :: Maybe Double
  , window :: Maybe Int
  , schema :: Text
  , params :: Maybe Double
  , docFit :: Text
  , licence :: Text
  , summary :: Text
  , blurb :: Text
  , measuredOn :: Text
  , problems :: [Text]
  , charsPerToken :: Double
  }

data Feel = Conversational | Readable | Batch | Unmeasured
  deriving stock (Eq)

feelOf :: Row -> Feel
feelOf r = case r.decode of
  Nothing -> Unmeasured
  Just d
    | d >= 5 -> Conversational
    | d >= 2 -> Readable
    | otherwise -> Batch

feelName :: Feel -> Text
feelName = \case
  Conversational -> "conversational"
  Readable -> "readable"
  Batch -> "batch"
  Unmeasured -> "-"

rowsOf :: Value -> [Row]
rowsOf doc =
  [ rowOf (cpt bk) bk nm e
  | Just (Object backends) <- [at ["models"] doc]
  , (bkKey, Object ms) <- KeyMap.toList backends
  , (nmKey, e) <- KeyMap.toList ms
  , let bk = Key.toText bkKey
  , let nm = Key.toText nmKey
  ]
  where
    cpt bk = fromMaybe 3.5 (num ["backends", bk, "charsPerToken"] doc)

rowOf :: Double -> Text -> Text -> Value -> Row
rowOf cpt bk nm e =
  Row
    { backend = bk
    , model = nm
    , decode = num ["measured", "decode", "tokPerSec"] e
    , prefill = largestPrefill
    , warm = num ["measured", "warmPrefillSeconds"] e
    , window = round <$> num ["measured", "window"] e
    , schema = maybe "-" (T.strip . T.takeWhile (/= ':')) (txt ["measured", "schema"] e)
    , params = paramsFrom nm `orElse` (txt ["summary"] e >>= paramsFrom)
    , docFit = fromMaybe "-" (txt ["docFit"] e)
    , licence = fromMaybe "-" (txt ["licence"] e)
    , summary = fromMaybe "" (txt ["summary"] e)
    , blurb = fromMaybe "" (txt ["blurb"] e)
    , measuredOn = fromMaybe "" (txt ["measured", "on"] e)
    , problems = case at ["measured", "problems"] e of
        Just (Array xs) -> [t | String t <- foldr (:) [] xs]
        _ -> []
    , charsPerToken = cpt
    }
  where
    largestPrefill = case at ["measured", "prefill"] e of
      Just (Array xs) -> listToMaybe (sortBy (comparing (Down . fst)) (mapMaybe point (foldr (:) [] xs)))
      _ -> Nothing
    point v = (,) <$> (round <$> num ["promptTokens"] v) <*> num ["tokPerSec"] v
    orElse a b = maybe b Just a

-- | Billions of parameters from a name like "qwen2.5-coder:7b" or a summary
-- like "Qwen2.5-7B-Instruct": the first word-piece that is a number followed
-- by b. "gemma2" and "qwen2.5" are not, because nothing follows with a b.
paramsFrom :: Text -> Maybe Double
paramsFrom t =
  listToMaybe
    [ n
    | piece <- T.split (\c -> not (isAlphaNum c || c == '.')) (T.map toLower t)
    , Just digits <- [T.stripSuffix "b" piece]
    , not (T.null digits)
    , T.all (\c -> isDigit c || c == '.') digits
    , Just n <- [readMaybe (T.unpack (if T.head digits == '.' then "0" <> digits else digits))]
    , n > 0
    ]

at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= at ks
at _ _ = Nothing

num :: [Text] -> Value -> Maybe Double
num p v = case at p v of
  Just (Number n) -> Just (toRealFloat n)
  _ -> Nothing

txt :: [Text] -> Value -> Maybe Text
txt p v = case at p v of
  Just (String t) -> Just t
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Options

data SortKey = ByDecode | ByPrefill | ByParams | ByWarm | ByWindow | ByName
  deriving stock (Eq, Enum, Bounded)

sortName :: SortKey -> Text
sortName = \case
  ByDecode -> "decode"
  ByPrefill -> "prefill"
  ByParams -> "params"
  ByWarm -> "warm"
  ByWindow -> "window"
  ByName -> "name"

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
      [] -> Left ("unknown sort column " <> s <> "; use decode, prefill, params, warm, window or name")
    go _ (a : _) = Left ("unknown argument " <> a <> "\nusage: llmq-models [--sort decode|prefill|params|warm|window|name] [--tui] [--catalogue FILE]")

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
    then runTui rows opts.sortKey
    else mapM_ TIO.putStrLn (tableLines 200 (sortRows opts.sortKey False rows) Nothing)

-- ---------------------------------------------------------------------------
-- Sorting and the table

-- | Unmeasured rows always sort last, whichever direction is chosen.
sortRows :: SortKey -> Bool -> [Row] -> [Row]
sortRows key reversed = sortBy cmp
  where
    cmp a b = case key of
      ByName -> flipIf (comparing (\r -> (r.backend, r.model)) a b)
      ByDecode -> big (.decode) a b
      ByPrefill -> big (fmap snd . (.prefill)) a b
      ByParams -> big (.params) a b
      ByWarm -> small (.warm) a b
      ByWindow -> big (fmap (fromIntegral :: Int -> Double) . (.window)) a b
    flipIf o = if reversed then compare EQ o else o
    big f a b = measured (\x y -> compare (Down x) (Down y)) f a b
    small f a b = measured compare f a b
    measured c f a b = case (f a, f b) of
      (Just x, Just y) -> flipIf (c x y)
      (Just _, Nothing) -> LT
      (Nothing, Just _) -> GT
      (Nothing, Nothing) -> comparing (.model) a b

tableLines :: Int -> [Row] -> Maybe Int -> [Text]
tableLines width rows selected =
  cut header : cut (T.replicate (min width (T.length header)) "-") : zipWith line [0 ..] rows
  where
    header = cols "backend" "model" "params" "decode" "prefill" "feel"
    line i r =
      let t =
            cut
              ( cols
                  r.backend
                  r.model
                  (maybe "-" (\p -> "~" <> showNum p <> "B") r.params)
                  (maybe "-" (fmt "%.2f") r.decode)
                  (maybe "-" (fmt "%.1f" . snd) r.prefill)
                  (feelName (feelOf r))
              )
       in if selected == Just i then "\ESC[7m" <> T.justifyLeft width ' ' t <> "\ESC[0m" else t
    cols a b c d e f =
      T.intercalate "  " [pad 7 a, pad 30 b, padL 6 c, padL 7 d, padL 8 e, f]
    cut = T.take width
    pad n t = T.justifyLeft n ' ' (T.take n t)
    padL n t = T.justifyRight n ' ' (T.take n t)

-- | The selected model's specs: the only place they appear.
panel :: Int -> Row -> [Text]
panel width r =
  [ T.replicate (min width 100) "-"
  , bold (r.backend <> "/" <> r.model) <> dim (if T.null r.measuredOn then "   not measured" else "   measured " <> r.measuredOn)
  , spec "decode" (maybe "not measured" (\d -> fmt "%.2f tok/s" d <> ", " <> feelName (feelOf r) <> answerTime d) r.decode)
  , spec "prefill" (maybe "not measured" (\(n, s) -> fmt "%.1f tok/s" s <> " on a " <> T.pack (show n) <> "-token prompt") r.prefill)
  , spec "warm" (maybe "-" (\w -> fmt "%.1f s" w <> " to re-read that prompt from the prefix cache") r.warm)
  , spec "window" (maybe "-" (\w -> T.pack (show w) <> " tokens") r.window)
  , spec "params" (maybe "unknown" (\p -> "about " <> showNum p <> " billion, read from the name") r.params)
  , spec "schema" r.schema
  , spec "docs" r.docFit
  , spec "licence" r.licence
  ]
    <> concatMap (wrap width) (filter (not . T.null) [r.summary])
    <> map (("\ESC[31mPROBLEM\ESC[0m " <>) . T.take (width - 8) . T.takeWhile (/= '\n')) r.problems
  where
    spec k v = dim (T.justifyLeft 9 ' ' k) <> T.take (width - 9) v
    answerTime d = "; a 200-token answer takes about " <> duration (200 / d)

bold, dim :: Text -> Text
bold t = "\ESC[1m" <> t <> "\ESC[0m"
dim t = "\ESC[2m" <> t <> "\ESC[0m"

fmt :: String -> Double -> Text
fmt f x = T.pack (printf f x)

showNum :: Double -> Text
showNum x = if x == fromIntegral (round x :: Int) then T.pack (show (round x :: Int)) else fmt "%.1f" x

duration :: Double -> Text
duration s
  | s < 90 = T.pack (show (round s :: Int)) <> " s"
  | otherwise = T.pack (show (round (s / 60) :: Int)) <> " min"

wrap :: Int -> Text -> [Text]
wrap width t = go (T.words (T.map (\c -> if isSpace c then ' ' else c) t))
  where
    go [] = []
    go ws = let (l, rest) = fill ws 0 [] in T.unwords l : go rest
    fill [] _ acc = (reverse acc, [])
    fill (w : ws) n acc
      | null acc = fill ws (T.length w) [w]
      | n + 1 + T.length w > width = (reverse acc, w : ws)
      | otherwise = fill ws (n + 1 + T.length w) (w : acc)

-- ---------------------------------------------------------------------------
-- The graph

data Metric = MDecode | MPrefill
  deriving stock (Eq)

metricName :: Metric -> Text
metricName = \case
  MDecode -> "decode tok/s"
  MPrefill -> "prefill tok/s"

metricOf :: Metric -> Row -> Maybe Double
metricOf = \case
  MDecode -> (.decode)
  MPrefill -> fmap snd . (.prefill)

-- | Every model with a parameter count and a measurement, as a numbered
-- point: parameters across on a log scale (1.5B to 8B spans most of the
-- range, and a linear axis would crowd every small model into one column),
-- the chosen speed up on a linear one. For decode, the conversational line
-- at 5 tok/s is drawn across the plot.
graphLines :: Int -> Int -> Metric -> [Row] -> Int -> [Text]
graphLines width height metric rows selected =
  [bold ("parameters (log) against " <> metricName metric) <> dim "   y: switch axis   v: back to the table", ""]
    <> plot
    <> [xAxis, xLabels, ""]
    <> legend
    <> unplotted
  where
    numbered = zip [1 :: Int ..] rows
    pts = [(i, p, v, r) | (i, r) <- numbered, Just p <- [r.params], Just v <- [metricOf metric r]]
    ymax = maximum (1 : [v | (_, _, v, _) <- pts]) * 1.1
    lo = log 1
    hi = log 10
    gw = max 20 (width - 10)
    -- Whatever height the legend and axes leave, capped so the plot stays
    -- readable rather than stretched.
    gh = max 6 (min 18 (height - 7 - length legend - length unplotted))
    colOf p = min (gw - 1) (max 0 (round ((log (max 1 p) - lo) / (hi - lo) * fromIntegral (gw - 1))))
    rowOfV v = min (gh - 1) (max 0 (gh - 1 - round (v / ymax * fromIntegral (gh - 1))))
    labelOf i = T.pack (show i)
    isSel r = case drop selected rows of
      (s : _) -> s.model == r.model && s.backend == r.backend
      [] -> False
    -- Points that land on the same spot (four 1.5B models at similar speed)
    -- are moved right to the nearest free place on their row, so every
    -- label stays readable. The position is then approximate by a few
    -- columns, which the legend makes up for.
    placed = foldl place [] pts
    place acc (i, p, v, r) =
      let w = T.length (labelOf i)
          y = rowOfV v
          x0 = colOf p
          free x = x >= 0 && x + w <= gw && and [not (taken x' y) | x' <- [x - 1 .. x + w]]
          taken x' y' = or [y'' == y' && x' >= xs && x' < xs + T.length (labelOf j) | (j, xs, y'', _) <- acc]
          candidates = concat [[x0 + d, x0 - d] | d <- [0 .. gw]]
       in case filter free candidates of
            (x : _) -> acc <> [(i, x, y, r)]
            [] -> acc
    plot =
      [ yLabel y <> " │" <> T.concat (render y 0)
      | y <- [0 .. gh - 1]
      ]
    render y x
      | x >= gw = []
      | otherwise =
          case [(i, r) | (i, xs, y', r) <- placed, y' == y, xs == x] of
            ((i, r) : _) ->
              let s = labelOf i
                  shown = if isSel r then "\ESC[7m" <> s <> "\ESC[0m" else colourFeel r s
               in shown : render y (x + T.length s)
            [] ->
              (if metric == MDecode && y == rowOfV 5 then dim "·" else " ") : render y (x + 1)
    yLabel y
      | y == 0 = T.justifyRight 6 ' ' (fmt "%.1f" ymax)
      | y == gh - 1 = T.justifyRight 6 ' ' "0"
      | metric == MDecode && y == rowOfV 5 = T.justifyRight 6 ' ' "5 conv"
      | otherwise = T.replicate 6 " "
    xAxis = T.replicate 7 " " <> "└" <> T.replicate gw "─"
    xLabels =
      T.replicate 8 " "
        <> T.concat
          [ T.justifyLeft (colOf b' - colOf a) ' ' (showNum a <> "B")
          | (a, b') <- zip [1, 2, 3, 5, 7] [2, 3, 5, 7, 10]
          ]
        <> "10B"
    -- Two columns when the terminal is wide enough, so the legend costs
    -- half the height.
    legendEntry (i, _, _, r) =
      T.justifyRight 3 ' ' (labelOf i) <> " " <> colourFeel r (T.justifyLeft 38 ' ' (T.take 37 (r.backend <> "/" <> r.model)))
    legend
      | width >= 90 = pairUp (map legendEntry pts)
      | otherwise = map legendEntry pts
    pairUp (x : y : rest) = (x <> "  " <> y) : pairUp rest
    pairUp [x] = [x]
    pairUp [] = []
    unplotted =
      case [r | (_, r) <- numbered, not (isJust r.params && isJust (metricOf metric r))] of
        [] -> []
        rs -> ["", dim ("not plotted, no parameter count or no measurement: " <> T.intercalate ", " [r.model | r <- rs])]

colourFeel :: Row -> Text -> Text
colourFeel r t = case feelOf r of
  Conversational -> "\ESC[32m" <> t <> "\ESC[0m"
  Readable -> "\ESC[33m" <> t <> "\ESC[0m"
  Batch -> "\ESC[31m" <> t <> "\ESC[0m"
  Unmeasured -> t

-- ---------------------------------------------------------------------------
-- The interactive loop

data View = TableView | GraphView
  deriving stock (Eq)

data Tui = Tui
  { rows :: [Row]
  , key :: SortKey
  , reversed :: Bool
  , cursor :: Int
  , view :: View
  , metric :: Metric
  }

runTui :: [Row] -> SortKey -> IO ()
runTui rs k = do
  oldBuf <- hGetBuffering stdin
  oldEcho <- hGetEcho stdin
  enterScreen
  loop (Tui rs k False 0 TableView MDecode)
    `finally` do
      leaveScreen
      hSetBuffering stdin oldBuf
      hSetEcho stdin oldEcho

enterScreen :: IO ()
enterScreen = do
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  hSetBuffering stdout (BlockBuffering Nothing)
  TIO.putStr "\ESC[?1049h\ESC[?25l"
  hFlush stdout

leaveScreen :: IO ()
leaveScreen = do
  TIO.putStr "\ESC[?25h\ESC[?1049l"
  hFlush stdout
  hSetBuffering stdout NoBuffering
  hSetBuffering stdin LineBuffering
  hSetEcho stdin True

loop :: Tui -> IO ()
loop st = do
  (height, width) <- termSize
  let sorted = sortRows st.key st.reversed st.rows
      n = length sorted
      cur = max 0 (min (n - 1) st.cursor)
      selectedRow = listToMaybe (drop cur sorted)
      status =
        (if st.view == TableView then "table" else "graph")
          <> "   sort: " <> sortName st.key <> (if st.reversed then " (reversed)" else "")
          <> "   " <> T.pack (show (cur + 1)) <> "/" <> T.pack (show n)
          <> "   enter ask  v view  y axis  s sort  r reverse  q quit"
      body = case st.view of
        TableView ->
          let panelLines = maybe [] (panel width) selectedRow
              room = max 1 (height - 3 - length panelLines)
              top = max 0 (cur - room + 1)
           in tableLines width (take room (drop top sorted)) (Just (cur - top)) <> panelLines
        GraphView -> graphLines width height st.metric sorted cur
  TIO.putStr "\ESC[H\ESC[2J"
  mapM_ TIO.putStrLn (take (height - 1) body)
  TIO.putStr ("\ESC[" <> T.pack (show height) <> ";1H\ESC[7m" <> T.justifyLeft width ' ' (T.take width status) <> "\ESC[0m")
  hFlush stdout
  k <- readKey
  let st' = st {cursor = cur}
  case k of
    KQuit -> pure ()
    KDown -> loop st' {cursor = min (n - 1) (cur + 1)}
    KUp -> loop st' {cursor = max 0 (cur - 1)}
    KTop -> loop st' {cursor = 0}
    KBottom -> loop st' {cursor = n - 1}
    KSort -> loop st' {key = if st.key == maxBound then minBound else succ st.key, cursor = 0}
    KReverse -> loop st' {reversed = not st.reversed, cursor = 0}
    KView -> loop st' {view = if st.view == TableView then GraphView else TableView}
    KAxis -> loop st' {metric = if st.metric == MDecode then MPrefill else MDecode}
    KAsk -> do
      mapM_ askModel selectedRow
      loop st'
    KOther -> loop st'

data Key = KUp | KDown | KTop | KBottom | KSort | KReverse | KView | KAxis | KAsk | KQuit | KOther

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

-- ---------------------------------------------------------------------------
-- Asking

-- | Ask one question through llmq, with a live indicator until the first
-- words arrive and a summary at the end.
askModel :: Row -> IO ()
askModel r = do
  leaveScreen
  let target = r.backend <> "/" <> r.model
  TIO.putStrLn ""
  TIO.putStr (bold ("ask " <> target) <> dim " (empty line cancels): ")
  hFlush stdout
  q <- T.strip <$> TIO.getLine
  unless (T.null q) do
    TIO.putStrLn ("\n" <> dim (expectation r q) <> "\n")
    runAsk target q
    TIO.putStr (dim "\n[any key returns]")
    hFlush stdout
    hSetBuffering stdin NoBuffering
    hSetEcho stdin False
    _ <- getChar
    pure ()
  enterScreen

-- | What to expect, from this model's measurements. The prompt is the
-- question plus about 40 tokens of chat template.
expectation :: Row -> Text -> Text
expectation r q =
  case (r.prefill, r.decode) of
    (Just (_, pre), Just dec) ->
      let promptTokens = fromIntegral (T.length q) / r.charsPerToken + 40
       in "first words expected after about "
            <> duration (promptTokens / pre + 1)
            <> ", then "
            <> fmt "%.1f" dec
            <> " tok/s, so a 200-token answer takes about "
            <> duration (200 / dec)
            <> ". Add the load time if this model is not already in memory."
    _ -> "this model has no measurement, so there is no estimate"

-- | Run `llmq ask`, showing a spinner until the first output arrives, then
-- passing the output through as it comes.
runAsk :: Text -> Text -> IO ()
runAsk target q = do
  started <- getCurrentTime
  result <- try do
    (_, Just out, _, ph) <-
      createProcess
        (proc "llmq" ["ask", "-m", T.unpack target, T.unpack q])
          { std_out = CreatePipe
          , std_err = Inherit
          }
    hSetBuffering out NoBuffering
    firstOutput <- newEmptyMVar
    bytes <- newMVar (0 :: Int)
    _ <- forkIO (spinner started firstOutput)
    let pump seen = do
          chunk <- BS.hGetSome out 256
          unless (BS.null chunk) do
            unless seen do
              putMVar firstOutput ()
              threadDelay 50000
              TIO.putStr "\r\ESC[2K"
            BS.hPut stdout chunk
            hFlush stdout
            modifyMVar_ bytes (pure . (+ BS.length chunk))
            pump True
    pump False
    gotAny <- isJust <$> tryReadMVar firstOutput
    unless gotAny (putMVar firstOutput () >> threadDelay 50000 >> TIO.putStr "\r\ESC[2K")
    code <- waitForProcess ph
    finished <- getCurrentTime
    n <- readMVar bytes
    let secs = realToFrac (diffUTCTime finished started) :: Double
        tokens = fromIntegral n / 4 :: Double
    TIO.putStrLn ""
    TIO.putStrLn
      ( dim
          ( "done in " <> duration secs
              <> (if n > 0 then fmt ", about %.0f tokens" tokens <> fmt ", %.1f tok/s overall" (tokens / max 1 secs) else "")
              <> case code of
                ExitSuccess -> ""
                ExitFailure c -> ", llmq exited " <> T.pack (show c)
          )
      )
  case result of
    Left (e :: SomeException) -> TIO.putStrLn ("\nllmq failed: " <> T.pack (show e))
    Right () -> pure ()

-- | A spinner with the seconds elapsed, on one line, until the first output.
spinner :: UTCTime -> MVar () -> IO ()
spinner started done = go (0 :: Int)
  where
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: String
    go i = do
      finished <- isJust <$> tryReadMVar done
      unless finished do
        now <- getCurrentTime
        let secs = round (realToFrac (diffUTCTime now started) :: Double) :: Int
        TIO.putStr ("\r\ESC[2K" <> T.singleton (frames !! (i `mod` length frames)) <> dim (" thinking, " <> T.pack (show secs) <> " s"))
        hFlush stdout
        threadDelay 150000
        go (i + 1)

-- | Rows and columns of the controlling terminal, from stty. Falls back to
-- 24 by 100 when there is no terminal to ask, or when it reports zero.
termSize :: IO (Int, Int)
termSize = do
  out <- readCreateProcess (shell "stty size < /dev/tty 2>/dev/null || true") ""
  pure case map readMaybe (words out) of
    [Just h, Just w] | h > 0 && w > 0 -> (h, w)
    _ -> (24, 100)

die' :: String -> IO a
die' msg = hPutStrLn stderr ("llmq-models: " <> msg) >> exitFailure