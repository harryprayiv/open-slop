-- | llmq-grace: run a Grace stage over the parts of a job.
--
-- llmq sends text and keeps prose. This sends the same parts through a
-- Grace function and keeps a typed value: the gateway constrains the
-- model's output to the schema Grace derived from the stage's result type,
-- Grace decodes it against that type, and the coverage check is a
-- comparison of field values rather than a search through headings.
--
-- The job machinery is llmq's, unchanged: one part per file by default,
-- finished parts on disk, resume by id, one runner at a time.
--
-- ============================================================================
-- WHAT IS AND IS NOT CHECKED AT BUILD TIME
-- ============================================================================
--
-- The stage's Haskell result type is in this binary. A .ffg whose type does
-- not match it fails to load, before any request. What the model puts in
-- those fields is not checked by anything here; the coverage warning says
-- which files it left out, and reading the result is still a person's job.
--
-- A generic mode that takes any stage type and writes the JSON through
-- without a Haskell type (--json) is the obvious next form of this, and is
-- not written yet: every stage today has a type in the binary.
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (encode)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Grace.Decode (Key (..))
import OpenSlop.Catalogue (Budget (..))
import OpenSlop.Grace.Docs (Docs, missingFiles, renderDocs)
import OpenSlop.Job
import OpenSlop.Stats (Stats (..))
import Options.Applicative
import Stage
import System.Directory (doesFileExist, getHomeDirectory, removePathForcibly)
import System.Environment (lookupEnv, setEnv)
import System.Exit
import System.FilePath ((</>))
import System.IO
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)
import Text.Printf (printf)

data Opts = Opts
  { stageFile :: FilePath
  , gateway :: Maybe Text
  , keyFile :: Maybe FilePath
  , model :: Text
  , input :: Maybe FilePath
  , out :: Maybe FilePath
  , stateRoot :: FilePath
  , chunkBytes :: Int
  , resume :: Maybe Text
  , dryRun :: Bool
  , fresh :: Bool
  , packed :: Bool
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> strOption (long "stage" <> metavar "FILE.ffg" <> help "a Grace function from the stage's arguments to its result")
    <*> optional (strOption (long "gateway" <> metavar "URL" <> help "sets OPENAI_BASE_URL for Grace (default: whatever is in the environment)"))
    <*> optional (strOption (long "key-file" <> metavar "FILE" <> help "bearer key for the gateway (default $LLMQ_KEY_FILE)"))
    <*> strOption (long "model" <> short 'm' <> metavar "ID" <> help "the model id the gateway serves, row/backend/name")
    <*> optional (strOption (long "input" <> short 'i' <> metavar "FILE"))
    <*> optional (strOption (long "out" <> short 'o' <> metavar "FILE" <> help "also copy the assembled document here"))
    <*> strOption (long "state" <> short 's' <> metavar "DIR" <> value "" <> help "job root (default $LLMQ_STATE, else ~/.local/state/llmq)")
    <*> option auto (long "chunk-bytes" <> short 'c' <> metavar "N" <> value 12000 <> showDefault <> help "input bytes per part; the gateway refuses anything past the model's window anyway")
    <*> optional (strOption (long "resume" <> short 'r' <> metavar "ID"))
    <*> switch (long "dry-run" <> short 'n' <> help "show the parts, send nothing")
    <*> switch (long "fresh" <> help "discard an existing job for this input first")
    <*> switch (long "packed" <> help "fill parts to the budget instead of one file per part")

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  let onSignal = Catch do
        TIO.hPutStrLn stderr "\nllmq-grace: interrupted. Finished parts are kept; run the same command or -r ID to continue."
        exitImmediately (ExitFailure 130)
  _ <- installHandler sigINT onSignal Nothing
  _ <- installHandler sigTERM onSignal Nothing

  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "run a Grace stage over the parts of a job, keeping typed results"))

  forM_ o.gateway \url -> setEnv "OPENAI_BASE_URL" (T.unpack url)
  base <- lookupEnv "OPENAI_BASE_URL"
  when (null base) (die' "no gateway: pass --gateway URL or set OPENAI_BASE_URL")

  keyPath <- maybe (lookupEnv "LLMQ_KEY_FILE") (pure . Just) o.keyFile >>= maybe (die' "no key: pass --key-file or set LLMQ_KEY_FILE") pure
  keyText <- T.strip <$> TIO.readFile keyPath
  when (T.null keyText) (die' ("the key file " <> T.pack keyPath <> " is empty"))

  root <-
    if null o.stateRoot
      then
        lookupEnv "LLMQ_STATE" >>= \case
          Just r -> pure r
          Nothing -> do
            xdg <- lookupEnv "XDG_STATE_HOME"
            home <- getHomeDirectory
            pure (fromMaybe (home </> ".local/state") xdg </> "llmq")
      else pure o.stateRoot

  -- The stage is loaded before anything else, so a .ffg whose type does not
  -- match this binary fails now rather than after the first part.
  stageSource <- TIO.readFile o.stageFile
  stage <- loadDocsStage o.stageFile
  say ("stage " <> T.pack o.stageFile <> " loaded and type-checked against Docs")

  -- The budget only shapes the parts and the job's identity here; the
  -- gateway holds the real window and refuses anything past it.
  let budget =
        Budget
          { chunkBytes = o.chunkBytes
          , ctx = 0
          , predict = 0
          , bytesPerToken = 2.8
          , temperature = Nothing
          }
      perFile = not o.packed

  job <- case o.resume of
    Just jid -> open root (JobId jid)
    Nothing -> do
      path <- maybe (die' "no input: pass -i FILE") pure o.input
      ok <- doesFileExist path
      unless ok (die' ("no such file: " <> T.pack path))
      t <- TE.decodeUtf8With TE.lenientDecode <$> B.readFile path
      when (T.null (T.strip t)) (die' "the input is empty")
      say ("input: " <> tshow (B.length (TE.encodeUtf8 t)) <> " bytes from " <> T.pack path)
      when o.fresh do
        let JobId jid = jobId o.model budget perFile stageSource t
        removePathForcibly (root </> T.unpack jid)
      (j, existed) <- create root o.model (T.pack path) budget perFile stageSource t
      let JobId jid = j.meta.id
      say (if existed then "job " <> jid <> " already exists; resuming it" else "job " <> jid <> " created in " <> T.pack j.dir)
      pure j

  when o.dryRun do
    say (tshow job.meta.parts <> " parts" <> (if perFile then " (one file per part)" else ""))
    forM_ job.manifest \m -> say ("  part " <> tshow m.index <> ": " <> tshow m.bytes <> " bytes, " <> T.intercalate ", " m.starts)
    exitSuccess

  let JobId jid = job.meta.id
  result <- withJobLock job (runParts stage (Key keyText) o.model job)
  when (null result) (die' ("job " <> jid <> " is already running in another llmq-grace"))

  outPath <- assemble job
  forM_ o.out \dest -> TIO.readFile outPath >>= TIO.writeFile dest
  warnings <- fmap concat $ forM job.manifest \m -> do
    st <- partState job m.index
    pure case st of
      Done s | not (null s.warnings) -> ["part " <> tshow m.index <> ": " <> T.intercalate "; " s.warnings]
      _ -> []
  putStrLn outPath
  if null warnings
    then say "finished"
    else do
      say "finished WITH WARNINGS:"
      mapM_ (say . ("  " <>)) warnings
      exitWith (ExitFailure 2)

runParts :: (PartArgs -> IO Docs) -> Key -> Text -> Job -> IO ()
runParts stage key model job = do
  let total = job.meta.parts
      JobId jid = job.meta.id
  states <- forM job.manifest \m -> (m,) <$> partState job m.index
  let todo = [m | (m, Pending) <- states]
  say (tshow (total - length todo) <> " of " <> tshow total <> " parts already done, " <> tshow (length todo) <> " to go")
  forM_ todo \m -> do
    body <- TIO.readFile (job.dir </> "chunks" </> (printf "%04d" m.index <> ".txt"))
    let args =
          PartArgs
            { key
            , model = Just model
            , path = fromMaybe (fromMaybe "" m.continues) (headMay m.starts)
            , source = body
            , part = m.index
            , parts = total
            }
    say ("part " <> tshow m.index <> "/" <> tshow total <> ": " <> tshow m.bytes <> " bytes, " <> T.intercalate ", " m.starts)
    t0 <- nowSeconds
    r <- try @SomeException (stage args)
    t1 <- nowSeconds
    case r of
      Left e -> do
        let why = T.pack (displayException e)
        recordFailure job m.index (TE.encodeUtf8 why) (BL.toStrict (encode (Nothing :: Maybe ())))
        say ("part " <> tshow m.index <> " FAILED: " <> why)
        say ("continue with: llmq-grace -r " <> jid)
        exitFailure
      Right docs -> do
        let skipped = missingFiles m.starts docs
            stats =
              Stats
                { part = m.index
                , bytes = m.bytes
                , wallSeconds = t1 - t0
                , promptTokens = Nothing
                , outputTokens = Nothing
                , prefillTokPerSec = Nothing
                , genTokPerSec = Nothing
                , loadSeconds = Nothing
                , bytesPerToken = Nothing
                , hitLimit = False
                , serverTruncated = False
                , warnings =
                    [ "no entry for " <> T.intercalate ", " skipped <> " (" <> tshow (length skipped) <> " of " <> tshow (length m.starts) <> " files in this part)"
                    | not (null skipped)
                    ]
                }
        -- The typed value beside the rendered document: the next stage in a
        -- pipeline reads this, not the Markdown.
        BL.writeFile (job.dir </> "parts" </> (printf "%04d" m.index <> ".grace.json")) (encode docs)
        writePart job m.index (renderDocs docs) stats
        say ("part " <> tshow m.index <> " done in " <> tshow (t1 - t0) <> "s")
        forM_ stats.warnings \w -> say ("WARNING " <> w)

headMay :: [a] -> Maybe a
headMay = \case
  (x : _) -> Just x
  [] -> Nothing

nowSeconds :: IO Int
nowSeconds = floor <$> getPOSIXTime

say :: Text -> IO ()
say t = TIO.hPutStrLn stderr ("llmq-grace: " <> t)

die' :: Text -> IO a
die' t = say t >> exitFailure

tshow :: (Show a) => a -> Text
tshow = T.pack . show