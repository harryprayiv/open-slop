-- | llmq-grace's agent mode: load an agent step written in Grace, check it
-- against the Haskell 'Decision', and optionally run one step through the
-- gateway.
--
--   llmq-grace --agent-stage stages/agent-step.ffg
--       type-checks the stage against OpenSlop.Agent.Action and exits
--
--   llmq-grace --agent-stage stages/agent-step.ffg -m qwen2.5-coder:7b \
--       --gateway https://oracle:8443/v1 --task "add a --verbose flag"
--       sends the first step of that task and prints the decision as JSON
--
-- The second form is the end-to-end check of typed tool use: Grace derives
-- the schema from the union, the gateway passes it to the backend, the
-- backend's grammar keeps the model inside it, and Grace decodes the answer
-- into the Haskell type. llmq-agent sends the same schema itself; this
-- shows the Grace program and the Haskell program agree.
module AgentStep
  ( AgentOpts (..)
  , agentP
  , runAgentStep
  ) where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Foldable (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Grace.Decode (Key (..))
import OpenSlop.Agent.Action qualified as Action
import Options.Applicative
import Stage (AgentArgs (..), loadAgentStage)
import System.Environment (lookupEnv, setEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data AgentOpts = AgentOpts
  { stageFile :: FilePath
  , task :: Maybe Text
  , gateway :: Maybe Text
  , keyFile :: Maybe FilePath
  , model :: Maybe Text
  }

agentP :: Parser AgentOpts
agentP =
  AgentOpts
    <$> strOption (long "agent-stage" <> metavar "FILE.ffg" <> help "an agent step: load it against the Haskell Decision type")
    <*> optional (T.pack <$> strOption (long "task" <> metavar "TEXT" <> help "send the first step of this task and print the decision"))
    <*> optional (T.pack <$> strOption (long "gateway" <> metavar "URL" <> help "sets OPENAI_BASE_URL for Grace"))
    <*> optional (strOption (long "key-file" <> metavar "FILE" <> help "bearer key for the gateway (default $LLMQ_KEY_FILE)"))
    <*> optional (T.pack <$> strOption (long "model" <> short 'm' <> metavar "ID" <> help "the model id the gateway serves"))

runAgentStep :: AgentOpts -> IO ()
runAgentStep o = do
  loaded <- try @SomeException (loadAgentStage o.stageFile)
  step <- either (\e -> die' ("the stage does not match the Haskell Decision type:\n" <> T.pack (displayException e))) pure loaded
  say ("stage " <> T.pack o.stageFile <> " loaded and type-checked against Decision")
  forM_ o.task \t -> do
    forM_ o.gateway (setEnv "OPENAI_BASE_URL" . T.unpack)
    base <- lookupEnv "OPENAI_BASE_URL"
    case base of
      Nothing -> die' "no gateway: pass --gateway URL or set OPENAI_BASE_URL"
      Just _ -> pure ()
    m <- maybe (die' "pass -m MODEL to send a step") pure o.model
    keyPath <- maybe (lookupEnv "LLMQ_KEY_FILE") (pure . Just) o.keyFile >>= maybe (die' "no key: pass --key-file or set LLMQ_KEY_FILE") pure
    k <- T.strip <$> TIO.readFile keyPath
    d <-
      step
        AgentArgs
          { key = Key k
          , model = Just m
          , instructions = Action.instructions Action.allKinds
          , conversation = "Task:\n" <> t <> "\n\nNothing has been done yet. Choose the first step."
          }
    BLC.putStrLn (encode d)

say :: Text -> IO ()
say t = TIO.hPutStrLn stderr ("llmq-grace: " <> t)

die' :: Text -> IO a
die' t = say t >> exitFailure
