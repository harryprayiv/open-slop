-- | llmq-grace's measuring mode: run a set of closed Grace programs against
-- a gateway, several times each, and say what each one cost and whether it
-- worked.
--
--   llmq-grace --measure stages/measure -m oracle/llamacpp/qwen2.5-coder-7b \
--       --gateway http://127.0.0.1:8443/v1 --record ~/gateway.jsonl
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
--
-- Grace is meant to carry more of open-slop: typed stages for chase
-- annotations, the index's answers, the agent's steps, and programs that
-- write programs (import prompt). Before any of that is built on it, these
-- have to be known on the hardware that serves the models, and none of
-- them were (docs/HANDOFF.md, open questions 5 and 7):
--
--   * how long one typed call takes, and how much of that is Grace;
--   * how often the grammar-constrained answer decodes at the type the
--     program asked for, and at what output size it stops fitting;
--   * what import prompt costs: its grammar preamble is about 8,000
--     tokens, and how many repair rounds a generated program needs before
--     it type-checks;
--   * what the prompt cache is worth, which on llama-server should make
--     every call after the first in a session much cheaper.
--
-- ============================================================================
-- HOW A CALL IS SEEN
-- ============================================================================
--
-- Grace does not return a call's usage, and an import prompt makes as many
-- calls as its repairs need, so a program's calls are not visible from
-- here. The gateway sees all of them. Started with --record FILE it writes
-- one JSON object per chat request; this mode counts the file's lines
-- before each run and takes the lines written during it. Runs are
-- sequential and nothing else should use the gateway meanwhile, or another
-- client's requests are counted with these. Lines rather than times,
-- because a run can finish within the same millisecond as the one before
-- it, and two clocks in two processes cannot separate those.
--
-- Without --record, each run still reports its time, its outcome and its
-- value, and the call counts are missing.
--
-- ============================================================================
-- THE PROGRAMS
-- ============================================================================
--
-- Every .ffg file in the directory is one program, run as a closed
-- expression. The key and the model reach it the way tests/grace does,
-- through $OPEN_SLOP_KEY and $OPEN_SLOP_MODEL read with `env:VAR : Key`
-- and `env:VAR : Text`, so one directory runs against any model. The
-- shipped set is stages/measure; its README says which question each
-- program answers.
--
-- The first run of each program is reported apart from the rest. On a
-- server with a prompt cache it is the cold run, and the difference is
-- what the cache is worth to that program.
module Measure
  ( MeasureOpts (..)
  , measureP
  , runMeasure
  ) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, forM_, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.List (isSuffixOf, sort)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Grace.Input (Input (..), Mode (..))
import Grace.Interpret (interpret)
import Grace.Pretty qualified as Pretty
import Grace.Value qualified as Value
import Numeric (showFFloat)
import Options.Applicative
import System.Directory (doesFileExist, listDirectory)
import System.Environment (lookupEnv, setEnv)
import System.Exit (exitFailure)
import System.FilePath (takeBaseName, (</>))
import System.IO (Handle, IOMode (..), hSetBuffering, BufferMode (..), stderr, stdout, withFile)

data MeasureOpts = MeasureOpts
  { dir :: FilePath
  , reps :: Int
  , only :: [Text]
  , gateway :: Maybe Text
  , keyFile :: Maybe FilePath
  , model :: Text
  , recordFile :: Maybe FilePath
  , out :: Maybe FilePath
  }

measureP :: Parser MeasureOpts
measureP =
  MeasureOpts
    <$> strOption (long "measure" <> metavar "DIR" <> help "run every .ffg program in DIR against the gateway and report what each cost")
    <*> option auto (long "reps" <> metavar "N" <> value 3 <> showDefault <> help "runs of each program; the first is reported apart, as the cold run")
    <*> many (T.pack <$> strOption (long "only" <> metavar "NAME" <> help "run only the program with this name (file name without .ffg); repeat for several"))
    <*> optional (T.pack <$> strOption (long "gateway" <> metavar "URL" <> help "sets OPENAI_BASE_URL for Grace"))
    <*> optional (strOption (long "key-file" <> metavar "FILE" <> help "bearer key for the gateway (default $LLMQ_KEY_FILE)"))
    <*> (T.pack <$> strOption (long "model" <> short 'm' <> metavar "ID" <> help "the model id the gateway serves, row/backend/name"))
    <*> optional (strOption (long "record" <> metavar "FILE" <> help "the file the gateway's --record writes; without it, calls and tokens are not counted"))
    <*> optional (strOption (long "out" <> short 'o' <> metavar "FILE" <> help "one JSON line per run (default: standard output)"))

-- | What one run of one program came to.
data Run = Run
  { program :: Text
  , rep :: Int
  , ok :: Bool
  , seconds :: Double
  , typ :: Text
  , result :: Maybe Value
  , rendered :: Text
  , failure :: Text
  , calls :: [Value]
  -- ^ the gateway's records of the requests this run made
  }

runMeasure :: MeasureOpts -> IO ()
runMeasure o = do
  hSetBuffering stdout LineBuffering
  forM_ o.gateway (setEnv "OPENAI_BASE_URL" . T.unpack)
  lookupEnv "OPENAI_BASE_URL" >>= \case
    Nothing -> die' "no gateway: pass --gateway URL or set OPENAI_BASE_URL"
    Just _ -> pure ()
  keyPath <- maybe (lookupEnv "LLMQ_KEY_FILE") (pure . Just) o.keyFile >>= maybe (die' "no key: pass --key-file or set LLMQ_KEY_FILE") pure
  key <- T.strip <$> TIO.readFile keyPath
  when (T.null key) (die' ("the key file " <> T.pack keyPath <> " is empty"))
  setEnv "OPEN_SLOP_KEY" (T.unpack key)
  setEnv "OPEN_SLOP_MODEL" (T.unpack o.model)

  files <- sort . filter (".ffg" `isSuffixOf`) <$> listDirectory o.dir
  let chosen = [f | f <- files, null o.only || T.pack (takeBaseName f) `elem` o.only]
  when (null chosen) (die' ("no .ffg programs to run in " <> T.pack o.dir))
  forM_ o.recordFile \r -> do
    there <- doesFileExist r
    if there
      then say ("calls are counted from " <> T.pack r)
      else say ("WARNING: " <> T.pack r <> " does not exist yet; is the gateway running with --record " <> T.pack r <> "?")
  say (tshow (length chosen) <> " programs, " <> tshow o.reps <> " runs each, against " <> o.model)

  let emit h = do
        runs <- fmap concat $ forM chosen \f -> forM [1 .. max 1 o.reps] \i -> do
          r <- runOnce o (o.dir </> f) i
          BLC.hPutStrLn h (Aeson.encode (runValue r))
          say (describe r)
          pure r
        summarise runs
  case o.out of
    Nothing -> emit stdout
    Just path -> withFile path WriteMode \h -> hSetBuffering h LineBuffering >> emit (h :: Handle)

runOnce :: MeasureOpts -> FilePath -> Int -> IO Run
runOnce o file i = do
  let name = T.pack (takeBaseName file)
  before <- maybe (pure 0) (fmap length . recordLines) o.recordFile
  t0 <- realToFrac <$> getPOSIXTime
  r <- try @SomeException (interpret (Path file AsCode))
  t1 <- realToFrac <$> getPOSIXTime
  cs <- maybe (pure []) (fmap (decodeAll . drop before) . recordLines) o.recordFile
  pure case r of
    Left e ->
      Run {program = name, rep = i, ok = False, seconds = t1 - t0, typ = "", result = Nothing, rendered = "", failure = T.pack (displayException e), calls = cs}
    Right (ty, v) ->
      Run
        { program = name
        , rep = i
        , ok = True
        , seconds = t1 - t0
        , typ = Pretty.toText ty
        , result = Value.toJSON v
        , rendered = Pretty.toText (Value.quote v)
        , failure = ""
        , calls = cs
        }

-- | The record file's lines, none when it does not exist yet. Read
-- strictly, so the gateway's appends are seen on the next read.
recordLines :: FilePath -> IO [BC.ByteString]
recordLines path = do
  there <- doesFileExist path
  if there then filter (not . BC.null) . BC.lines <$> BC.readFile path else pure []

decodeAll :: [BC.ByteString] -> [Value]
decodeAll ls = [v | l <- ls, Just v@(Object _) <- [Aeson.decodeStrict l]]

field :: Text -> Value -> Maybe Value
field k = \case
  Object m -> KM.lookup (K.fromText k) m
  _ -> Nothing

num :: Text -> Value -> Double
num k v = case field k v of
  Just (Number n) -> toRealFloat n
  _ -> 0

isTrue :: Text -> Value -> Bool
isTrue k v = field k v == Just (Bool True)

textOf :: Text -> Value -> Text
textOf k v = case field k v of
  Just (String t) -> t
  _ -> ""

runValue :: Run -> Value
runValue r =
  object
    [ "program" .= r.program
    , "rep" .= r.rep
    , "ok" .= r.ok
    , "seconds" .= r.seconds
    , "type" .= r.typ
    , "value" .= r.result
    , "rendered" .= T.take 2000 r.rendered
    , "failure" .= T.take 2000 r.failure
    , "calls" .= length r.calls
    , "repairs" .= length (filter (isTrue "repair") r.calls)
    , "promptTokens" .= sum (map (num "promptTokens") r.calls)
    , "completionTokens" .= sum (map (num "completionTokens") r.calls)
    , "gatewaySeconds" .= sum (map (num "seconds") r.calls)
    , "outcomes" .= map (textOf "outcome") r.calls
    , "requests" .= r.calls
    ]

describe :: Run -> Text
describe r =
  r.program
    <> " #"
    <> tshow r.rep
    <> ": "
    <> (if r.ok then "ok" else "FAILED")
    <> " in "
    <> fixed 1 r.seconds
    <> " s"
    <> ( if null r.calls
           then ""
           else
             ", "
               <> tshow (length r.calls)
               <> " calls ("
               <> tshow (length (filter (isTrue "repair") r.calls))
               <> " repairs), "
               <> tshow (round (sum (map (num "promptTokens") r.calls)) :: Int)
               <> " prompt and "
               <> tshow (round (sum (map (num "completionTokens") r.calls)) :: Int)
               <> " completion tokens"
       )
    <> (if r.ok then "" else ": " <> T.take 300 (T.unwords (T.words r.failure)))

-- | Per program: how many runs worked, the cold run against the median of
-- the rest, and the calls and tokens a run took.
summarise :: [Run] -> IO ()
summarise runs = do
  let names = dedupe (map (.program) runs)
  say ""
  say "program                        ok    cold s   warm s   calls  repairs  prompt  completion"
  forM_ names \n -> do
    let rs = [r | r <- runs, r.program == n]
        cold = [r.seconds | r <- rs, r.rep == 1]
        warm = [r.seconds | r <- rs, r.rep > 1]
        mean xs = if null xs then 0 else sum xs / fromIntegral (length xs)
        perRun f = mean [f r | r <- rs]
    say
      ( pad 30 n
          <> " "
          <> pad 5 (tshow (length (filter (.ok) rs)) <> "/" <> tshow (length rs))
          <> " "
          <> padL 7 (maybe "-" (fixed 1) (median cold))
          <> "  "
          <> padL 7 (maybe "-" (fixed 1) (median warm))
          <> "  "
          <> padL 6 (fixed 1 (perRun (fromIntegral . length . (.calls))))
          <> "  "
          <> padL 7 (fixed 1 (perRun (fromIntegral . length . filter (isTrue "repair") . (.calls))))
          <> "  "
          <> padL 6 (fixed 0 (perRun (sum . map (num "promptTokens") . (.calls))))
          <> "  "
          <> padL 10 (fixed 0 (perRun (sum . map (num "completionTokens") . (.calls))))
      )
  when (all (null . (.calls)) runs) $
    say "no calls were matched: without --record, or with a gateway not started with --record, calls and tokens read 0"
  where
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) [] . reverse
    pad k t = T.justifyLeft k ' ' t
    padL k t = T.justifyRight k ' ' t

median :: [Double] -> Maybe Double
median [] = Nothing
median xs =
  let s = sort xs
      n = length s
   in Just
        ( if odd n
            then s !! (n `div` 2)
            else (s !! (n `div` 2 - 1) + s !! (n `div` 2)) / 2
        )

fixed :: Int -> Double -> Text
fixed d x = T.pack (showFFloat (Just d) x "")

say :: Text -> IO ()
say t = TIO.hPutStrLn stderr ("llmq-grace: " <> t)

die' :: Text -> IO a
die' t = say t >> exitFailure

tshow :: (Show a) => a -> Text
tshow = T.pack . show
