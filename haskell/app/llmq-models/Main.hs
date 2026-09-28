-- | llmq-models: the measured catalogue, as a table or as an interactive
-- browser.
--
-- Reads the catalogue llmq reads ($OPEN_SLOP_CATALOGUE, or --catalogue), so
-- it shows exactly the numbers llmq budgets from: everything llmq-bench
-- wrote into the consumer's catalogue.extra, merged over open-slop's own
-- entries by Nix.
--
--   llmq-models                    plain table, fastest decode first
--   llmq-models --sort prefill     sorted by another column
--   llmq-models --tui              interactive: pick a model and ask it
--
-- The interactive mode is plain ANSI escape codes over the terminal, with no
-- TUI library: one screen, one table, a detail pane. Keys:
--
--   j k, arrows     move            s    next sort column
--   g G             top, bottom     r    reverse the sort
--   enter, a        ask the selected model a question
--   d, space        show or hide its details
--   q               quit
--
-- Asking hands the question to `llmq ask -m BACKEND/NAME`, the same command
-- you would type, with its output going straight to the terminal as it
-- streams. When it finishes, any key returns to the table with the same
-- model selected. An empty question cancels.
--
-- Columns, all from the catalogue entry and its `measured` block:
--
--   decode    tok/s generating 128 tokens from a short prompt
--   prefill   tok/s on the largest cold prompt measured (about 4,000 tokens
--             on the CPU backends, 1,000 on the NPU)
--   warm      seconds for that same prompt a second time: the prefix cache
--   window    tokens one request can hold, as the server reports it
--   schema    whether a JSON Schema response_format was honoured
--
-- A model with no measurement shows dashes rather than being left out: an
-- unmeasured model is information too.
module Main (main) where

import Control.Exception (SomeException, finally, try)
import Data.Aeson (Value (..), eitherDecodeFileStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isSpace)
import Data.List (sortBy)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO
import System.Process (callProcess, readCreateProcess, shell)
import Text.Printf (printf)
import Text.Read (readMaybe)

data Row = Row
  { backend :: Text
  , model :: Text
  , decode :: Maybe Double
  , prefill :: Maybe (Int, Double)
  , warm :: Maybe Double
  , window :: Maybe Int
  , schema :: Text
  , docFit :: Text
  , licence :: Text
  , measuredOn :: Text
  , blurb :: Text
  , problems :: [Text]
  }

data SortKey = ByDecode | ByPrefill | ByWarm | ByWindow | ByName
  deriving stock (Eq, Enum, Bounded, Show)

sortName :: SortKey -> Text
sortName = \case
  ByDecode -> "decode"
  ByPrefill -> "prefill"
  ByWarm -> "warm"
  ByWindow -> "window"
  ByName -> "name"

parseSort :: String -> Maybe SortKey
parseSort = \case
  "decode" -> Just ByDecode
  "prefill" -> Just ByPrefill
  "warm" -> Just ByWarm
  "window" -> Just ByWindow
  "name" -> Just ByName
  _ -> Nothing

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
    go o ("--sort" : s : rest) = case parseSort s of
      Just k -> go o {sortKey = k} rest
      Nothing -> Left ("unknown sort column " <> s <> "; use decode, prefill, warm, window or name")
    go _ (a : _) = Left ("unknown argument " <> a <> "\nusage: llmq-models [--sort decode|prefill|warm|window|name] [--tui] [--catalogue FILE]")

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
    else mapM_ TIO.putStrLn (table 200 (sortRows opts.sortKey False rows) Nothing)

-- ---------------------------------------------------------------------------
-- Reading the catalogue

rowsOf :: Value -> [Row]
rowsOf doc =
  [ rowOf bk nm e
  | Just (Object backends) <- [at ["models"] doc]
  , (bkKey, Object ms) <- KeyMap.toList backends
  , (nmKey, e) <- KeyMap.toList ms
  , let bk = Key.toText bkKey
  , let nm = Key.toText nmKey
  ]

rowOf :: Text -> Text -> Value -> Row
rowOf bk nm e =
  Row
    { backend = bk
    , model = nm
    , decode = num ["measured", "decode", "tokPerSec"] e
    , prefill = largestPrefill
    , warm = num ["measured", "warmPrefillSeconds"] e
    , window = round <$> num ["measured", "window"] e
    , schema = shortSchema (txt ["measured", "schema"] e)
    , docFit = fromMaybe "-" (txt ["docFit"] e)
    , licence = fromMaybe "-" (txt ["licence"] e)
    , measuredOn = fromMaybe "" (txt ["measured", "on"] e)
    , blurb = fromMaybe "" (txt ["blurb"] e)
    , problems = case at ["measured", "problems"] e of
        Just (Array xs) -> [t | String t <- foldr (:) [] xs]
        _ -> []
    }
  where
    largestPrefill = case at ["measured", "prefill"] e of
      Just (Array xs) ->
        case sortBy (comparing (Down . fst)) (mapMaybe point (foldr (:) [] xs)) of
          (p : _) -> Just p
          [] -> Nothing
      _ -> Nothing
    point v = (,) <$> (round <$> num ["promptTokens"] v) <*> num ["tokPerSec"] v

shortSchema :: Maybe Text -> Text
shortSchema = \case
  Nothing -> "-"
  Just s -> T.strip (T.takeWhile (/= ':') s)

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
-- Sorting and rendering

-- | Unmeasured rows always sort last, whichever direction is chosen.
sortRows :: SortKey -> Bool -> [Row] -> [Row]
sortRows key reversed = sortBy cmp
  where
    cmp a b = case key of
      ByName -> flipIf (comparing (\r -> (r.backend, r.model)) a b)
      ByDecode -> measuredFirst (.decode) a b
      ByPrefill -> measuredFirst (fmap snd . (.prefill)) a b
      ByWarm -> measuredFirstAsc (.warm) a b
      ByWindow -> measuredFirst (fmap (fromIntegral :: Int -> Double) . (.window)) a b
    flipIf o = if reversed then invert o else o
    invert = \case LT -> GT; GT -> LT; EQ -> EQ
    -- Larger is better for rates and windows.
    measuredFirst f a b = case (f a, f b) of
      (Just x, Just y) -> flipIf (compare (Down x) (Down y))
      (Just _, Nothing) -> LT
      (Nothing, Just _) -> GT
      (Nothing, Nothing) -> comparing (.model) a b
    -- Smaller is better for seconds.
    measuredFirstAsc f a b = case (f a :: Maybe Double, f b) of
      (Just x, Just y) -> flipIf (compare x y)
      (Just _, Nothing) -> LT
      (Nothing, Just _) -> GT
      (Nothing, Nothing) -> comparing (.model) a b

-- | The table as lines, cut to the given width. The selected row, if any,
-- is drawn in reverse video.
table :: Int -> [Row] -> Maybe Int -> [Text]
table width rows selected =
  cut header : cut (T.replicate (T.length header) "-") : zipWith line [0 ..] rows
  where
    header = cols "backend" "model" "decode" "prefill" "warm" "window" "schema" "docs"
    line i r =
      let t =
            cut
              ( cols
                  r.backend
                  r.model
                  (maybe "-" (fmt "%.2f") r.decode)
                  (maybe "-" (\(n, s) -> fmt "%.1f" s <> " @" <> T.pack (show n)) r.prefill)
                  (maybe "-" (fmt "%.1fs") r.warm)
                  (maybe "-" (T.pack . show) r.window)
                  r.schema
                  r.docFit
              )
       in if selected == Just i then "\ESC[7m" <> t <> "\ESC[0m" else t
    cols a b c d e f g h =
      T.intercalate
        "  "
        [pad 8 a, pad 30 b, padL 7 c, padL 14 d, padL 7 e, padL 7 f, pad 9 g, h]
    cut = T.take width
    pad n t = T.justifyLeft n ' ' (T.take n t)
    padL n t = T.justifyRight n ' ' (T.take n t)
    fmt :: String -> Double -> Text
    fmt f x = T.pack (printf f x)

details :: Int -> Row -> [Text]
details width r =
  concatMap
    (wrap width)
    ( [ r.backend <> "/" <> r.model <> (if T.null r.measuredOn then "" else "   measured " <> r.measuredOn)
      , "licence: " <> r.licence
      , ""
      , r.blurb
      ]
        <> (if null r.problems then [] else "" : map ("PROBLEM " <>) r.problems)
    )

wrap :: Int -> Text -> [Text]
wrap width t
  | T.null t = [""]
  | otherwise = go (T.words (T.map (\c -> if isSpace c then ' ' else c) t))
  where
    go [] = []
    go ws =
      let (line, rest) = fill ws 0 []
       in T.unwords line : go rest
    fill [] _ acc = (reverse acc, [])
    fill (w : ws) n acc
      | null acc = fill ws (T.length w) [w]
      | n + 1 + T.length w > width = (reverse acc, w : ws)
      | otherwise = fill ws (n + 1 + T.length w) (w : acc)

-- ---------------------------------------------------------------------------
-- Interactive mode

data Tui = Tui
  { rows :: [Row]
  , key :: SortKey
  , reversed :: Bool
  , cursor :: Int
  , showDetails :: Bool
  }

runTui :: [Row] -> SortKey -> IO ()
runTui rs k = do
  oldBuf <- hGetBuffering stdin
  oldEcho <- hGetEcho stdin
  enterScreen
  loop (Tui rs k False 0 False)
    `finally` do
      leaveScreen
      hSetBuffering stdin oldBuf
      hSetEcho stdin oldEcho

-- | Raw keys, no echo, the alternate screen and a hidden cursor: the table.
enterScreen :: IO ()
enterScreen = do
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  hSetBuffering stdout (BlockBuffering Nothing)
  TIO.putStr "\ESC[?1049h\ESC[?25l"
  hFlush stdout

-- | Back to the normal screen with a visible cursor and line input: where
-- the question is typed and the answer streams.
leaveScreen :: IO ()
leaveScreen = do
  TIO.putStr "\ESC[?25h\ESC[?1049l"
  hFlush stdout
  hSetBuffering stdout LineBuffering
  hSetBuffering stdin LineBuffering
  hSetEcho stdin True

-- | Ask the selected model one question through llmq, then come back.
--
-- The answer is printed on the normal screen, so it stays in the
-- terminal's scrollback after the table is redrawn over it.
askModel :: Row -> IO ()
askModel r = do
  leaveScreen
  let target = r.backend <> "/" <> r.model
  TIO.putStrLn ""
  TIO.putStr ("ask " <> target <> " (empty line cancels): ")
  hFlush stdout
  q <- T.strip <$> TIO.getLine
  if T.null q
    then enterScreen
    else do
      TIO.putStrLn ""
      result <- try (callProcess "llmq" ["ask", "-m", T.unpack target, T.unpack q])
      case result of
        Left (e :: SomeException) -> TIO.putStrLn ("\nllmq failed: " <> T.pack (show e))
        Right () -> pure ()
      TIO.putStr "\n[any key returns to the table]"
      hFlush stdout
      hSetBuffering stdin NoBuffering
      hSetEcho stdin False
      _ <- getChar
      enterScreen

loop :: Tui -> IO ()
loop st = do
  (height, width) <- termSize
  let sorted = sortRows st.key st.reversed st.rows
      n = length sorted
      cur = max 0 (min (n - 1) st.cursor)
      detailLines = if st.showDetails then case drop cur sorted of
        (r : _) -> "" : details width r
        [] -> []
        else []
      -- Rows that fit: header, rule, the table, the detail pane, the status.
      room = max 1 (height - 3 - length detailLines)
      -- Scroll only as far as needed to keep the cursor on screen.
      top = max 0 (cur - room + 1)
      visible = take room (drop top sorted)
      tableLines = table width visible (Just (cur - top))
      status =
        "sort: " <> sortName st.key <> (if st.reversed then " (reversed)" else "")
          <> "   " <> T.pack (show (cur + 1)) <> "/" <> T.pack (show n)
          <> "   enter ask  d details  j/k move  s sort  r reverse  q quit"
  TIO.putStr "\ESC[H\ESC[2J"
  mapM_ TIO.putStrLn tableLines
  mapM_ TIO.putStrLn detailLines
  TIO.putStr ("\ESC[7m" <> T.take width status <> "\ESC[0m")
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
    KDetails -> loop st' {showDetails = not st.showDetails}
    KAsk -> do
      case drop cur sorted of
        (r : _) -> askModel r
        [] -> pure ()
      loop st'
    KOther -> loop st'

data Key = KUp | KDown | KTop | KBottom | KSort | KReverse | KDetails | KAsk | KQuit | KOther

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
    '\n' -> pure KAsk
    'a' -> pure KAsk
    'd' -> pure KDetails
    ' ' -> pure KDetails
    '\ESC' -> do
      -- An arrow key arrives as ESC [ A..D; a lone ESC is quit.
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