-- | llmq: send text to one model on one of the fleet's inference endpoints.
--
-- The client side of open-slop. Picks a model, cuts long input into parts that
-- fit its window, sends the parts one at a time, keeps each finished part on
-- disk, and resumes at the first unfinished part when run again.
--
-- The catalogue arrives as JSON in $SIBYL_CATALOGUE (Nix writes it from
-- catalogue/default.nix plus the consumer's endpoint options). Nothing here
-- knows an address.
--
-- Exit status: 0 done, 1 failed, 2 done with warnings.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (eitherDecodeFileStrict)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.IO.Encoding (setLocaleEncoding)
import Menu
import Options.Applicative hiding (header, info)
import Options.Applicative qualified as O
import Run
import open-slop.Catalogue
import open-slop.Engine (Prompt (..), Summary (..), buildRequest)
import open-slop.Http
import open-slop.Job
import open-slop.Stats (Stats (..), Verdict (..), judge)
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit
import System.FilePath ((</>))
import System.IO
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

-- ---------------------------------------------------------------------------
-- Options

data Cmd
  = Run RunOpts
  | List
  | Jobs
  | Ask AskOpts

data AskOpts = AskOpts
  { model :: Maybe Text
  , question :: Text
  }

commonP :: Parser Common
commonP =
  Common
    <$> strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON (default $SIBYL_CATALOGUE)" <> value "")
    <*> strOption (long "state" <> short 's' <> metavar "DIR" <> help "job root (default $LLMQ_STATE, else ~/.local/state/llmq)" <> value "")
    <*> optional (strOption (long "key-file" <> metavar "FILE" <> help "bearer key for the gateway (default $LLMQ_KEY_FILE)"))
    <*> option auto (long "timeout" <> short 't' <> metavar "SECS" <> help "limitSeconds for one request" <> value 14400 <> showDefault)

runP :: Parser RunOpts
runP =
  RunOpts
    <$> optional (strOption (long "model" <> short 'm' <> metavar "MODEL" <> help "ROW/BACKEND/NAME, BACKEND/NAME or NAME; skips the menu"))
    <*> optional (strOption (long "input" <> short 'i' <> metavar "SRC" <> help "clip, a file, or - for a pipe"))
    <*> optional (strOption (long "prompt" <> short 'p' <> metavar "TEXT" <> help "the instruction"))
    <*> optional (strOption (long "prompt-file" <> short 'P' <> metavar "FILE"))
    <*> optional (strOption (long "out" <> short 'o' <> metavar "FILE" <> help "also copy the finished document here"))
    <*> optional (option auto (long "chunk-bytes" <> short 'c' <> metavar "N" <> help "override the model's input budget"))
    <*> optional (strOption (long "resume" <> short 'r' <> metavar "ID"))
    <*> switch (long "dry-run" <> short 'n' <> help "show the parts, send nothing")
    <*> switch (long "fresh" <> help "discard an existing job for this input first")

askP :: Parser AskOpts
askP =
  AskOpts
    <$> optional (strOption (long "model" <> short 'm' <> metavar "MODEL"))
    <*> strArgument (metavar "QUESTION")

cmdP :: Parser (Common, Cmd)
cmdP =
  (,)
    <$> commonP
    <*> ( hsubparser
            ( command "run" (O.info (Run <$> runP) (progDesc "send text, as a resumable job (default)"))
                <> command "list" (O.info (pure List) (progDesc "every model, its status and constraints"))
                <> command "jobs" (O.info (pure Jobs) (progDesc "every job under the state directory"))
                <> command "ask" (O.info (Ask <$> askP) (progDesc "one question, no job"))
            )
            <|> (Run <$> runP)
        )

-- ---------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  -- Finished parts are already on disk; nothing else needs unwinding.
  let onSignal = Catch do
        TIO.hPutStrLn stderr "\nllmq: interrupted. Finished parts are kept; run the same command or -r ID to continue."
        exitImmediately (ExitFailure 130)
  _ <- installHandler sigINT onSignal Nothing
  _ <- installHandler sigTERM onSignal Nothing
  (common0, cmd) <-
    execParser (O.info (cmdP <**> helper) (fullDesc <> progDesc "llmq: send text to a local model, as a resumable job"))
  common <- fillDefaults common0
  cat <- eitherDecodeFileStrict common.catalogueFile >>= either (die' . T.pack) pure
  client <- newClient
  auth <- case common.keyFile of
    Nothing -> pure NoAuth
    Just f -> Bearer . T.strip <$> TIO.readFile f
  case cmd of
    List -> do
      p <- probe client auth cat
      forM_ cat.endpoints \ep -> TIO.putStrLn ("endpoint  " <> endpointId ep <> "  " <> ep.url)
      forM_ (Map.toList cat.backends) \(n, b) ->
        TIO.putStrLn ("\n" <> T.replicate 72 "=" <> "\nbackend " <> n <> "\n\n" <> T.stripEnd b.blurb)
      forM_ p.entries \e -> TIO.putStrLn (T.replicate 72 "=" <> "\n" <> card e)
      forM_ p.unavailable \u -> TIO.hPutStrLn stderr ("unavailable  " <> u)
    Jobs -> do
      js <- listJobs common.stateRoot
      when (null js) (say ("no jobs under " <> T.pack common.stateRoot))
      forM_ js \(m, done, complete) -> do
        let JobId jid = m.id
        TIO.putStrLn (jid <> "  " <> tshow done <> "/" <> tshow m.parts <> " parts  " <> m.model <> "  " <> tshow m.inputBytes <> " bytes  " <> tshow m.created)
        TIO.putStrLn ("    " <> if complete then T.pack (common.stateRoot </> T.unpack jid </> "output.md") else "incomplete")
    Ask o -> do
      p <- probe client auth cat
      e <- chooseEntry p o.model
      let req = buildRequest e.engine e.name (Prompt "" "" o.question) (samplingFor e.budget) e.streams
      out <- send client auth common.timeoutSeconds e req False
      case problem e out of
        Just why -> die' why
        Nothing -> do
          TIO.putStrLn out.summary.output
          forM_ out.summary.final \i -> case judge e.budget 0 0 out.wallSeconds i of
            Truncated why -> die' why
            Kept st -> do
              say (maybe "?" tshow st.promptTokens <> " prompt tokens, " <> maybe "?" tshow st.outputTokens <> " output tokens at " <> maybe "?" tshow st.genTokPerSec <> " tok/s")
              forM_ st.warnings \w -> say ("WARNING " <> w)
              unless (null st.warnings) (exitWith (ExitFailure 2))
    Run o -> runJob common client auth cat o

fillDefaults :: Common -> IO Common
fillDefaults c = do
  catFile <-
    if null c.catalogueFile
      then lookupEnv "SIBYL_CATALOGUE" >>= maybe (die' "no catalogue: pass --catalogue or set SIBYL_CATALOGUE") pure
      else pure c.catalogueFile
  root <-
    if null c.stateRoot
      then
        lookupEnv "LLMQ_STATE" >>= \case
          Just r -> pure r
          Nothing -> do
            xdg <- lookupEnv "XDG_STATE_HOME"
            home <- getHomeDirectory
            pure (fromMaybe (home </> ".local/state") xdg </> "llmq")
      else pure c.stateRoot
  key <- maybe (lookupEnv "LLMQ_KEY_FILE") (pure . Just) c.keyFile
  pure c {catalogueFile = catFile, stateRoot = root, keyFile = key}
