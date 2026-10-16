-- | llmq-agent: a local model works on a project, one typed action at a
-- time, with the compiler as the judge of every change.
--
--   llmq-agent --task "make parseDuration accept 90s and 1h30m"
--   llmq-agent --project ~/src/cheeblr --task-file task.md --model qwen2.5-coder:14b
--   llmq-agent --read-only --task "where is the gateway's window checked?"
--
-- The model is one on a LAN server named in the catalogue, as llmq-index
-- names its chat model, and the same capacity rules decide how much it is
-- sent. Each turn it returns a decision (a plan and one action) under a
-- grammar built from "OpenSlop.Agent.Action", so it cannot express
-- anything else. This program carries the action out:
--
--   * reads and edits happen in a git worktree on the branch
--     llmq-agent/<run>, never in your checkout; every edit is one commit
--   * after every edit tricorder rebuilds and runs the tests, and the
--     diagnostics are the model's next observation
--   * LookupSource answers from tricorder source, offline, for the
--     project and every installed library
--   * SearchIndex answers from llmq-index's store, when --index is given
--   * Finish after edits is accepted only on a clean build with passing
--     tests
--
-- Every step is written to $XDG_STATE_HOME/llmq-agent/<run>/steps.jsonl,
-- with the transcript beside it. When the run ends the worktree is removed
-- and the branch stays for you to review and merge.
--
-- Run it from the project's development shell, where `cabal repl` works,
-- because tricorder drives cabal there.
module Main (main) where

import Control.Exception (SomeException, finally, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Git qualified
import Loop
import OpenSlop.Agent.Action (Kind (..), allKinds)
import OpenSlop.Agent.Oracle (renderReport)
import OpenSlop.Agent.Workspace (listDirectory', openWorkspace, workspaceRoot)
import OpenSlop.Capacity (Capacity, capacityFor, describeCapacity, measuredEntry, probeWindow, promptCharsWithin)
import OpenSlop.Catalogue (Backend (..), Catalogue (..), Endpoint (..), Engine (..), endpointId, lookupModel)
import OpenSlop.ChatStream (Chat (..))
import OpenSlop.Http (Client, newClient)
import OpenSlop.Measured (loadCatalogue, measuredPath, readMeasured)
import OpenSlop.Rag.Embed (embedder)
import OpenSlop.Rag.Locality (Lan, onLan)
import OpenSlop.Rag.Retrieve (Retrieval (..), relevant, retrieve)
import OpenSlop.Rag.Store (Hit (..), connectStore, migrate)
import Options.Applicative
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, findExecutable, getXdgDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (makeRelative, (</>))
import System.IO (stderr)
import Tricorder (TricorderConfig (..))
import Tricorder qualified

data Opts = Opts
  { catalogueFile :: Maybe FilePath
  , chatAt :: Maybe String
  , model :: Maybe String
  , maxWait :: Maybe Double
  , project :: FilePath
  , task :: Maybe String
  , taskFile :: Maybe FilePath
  , from :: String
  , steps :: Int
  , readOnly :: Bool
  , inPlace :: Bool
  , oracle :: OracleChoice
  , tricorder :: Maybe FilePath
  , buildTimeout :: Int
  , settle :: Double
  , index :: Bool
  , db :: Maybe String
  , embedAt :: Maybe String
  , embedModel :: Maybe String
  , under :: [FilePath]
  }

data OracleChoice = OracleAuto | OracleTricorder | OracleNone

optsP :: Parser Opts
optsP =
  Opts
    <$> optional (strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON (default $OPEN_SLOP_CATALOGUE)"))
    <*> optional (strOption (long "chat-at" <> metavar "ROW/BACKEND" <> help "the model's server (default $OPEN_SLOP_AGENT_CHAT_AT, else $OPEN_SLOP_RAG_CHAT_AT)"))
    <*> optional (strOption (long "model" <> short 'm' <> metavar "NAME" <> help "the model (default $OPEN_SLOP_AGENT_MODEL, else $OPEN_SLOP_RAG_CHAT_MODEL)"))
    <*> optional (option auto (long "max-wait" <> metavar "SECS" <> help "keep each prompt small enough to be read within this time, at the measured prefill rate"))
    <*> strOption (long "project" <> short 'p' <> metavar "DIR" <> value "." <> showDefault <> help "the project; tricorder runs here")
    <*> optional (strOption (long "task" <> short 't' <> metavar "TEXT" <> help "what to do, or the question to answer"))
    <*> optional (strOption (long "task-file" <> metavar "FILE" <> help "the task, read from a file"))
    <*> strOption (long "from" <> metavar "REV" <> value "HEAD" <> showDefault <> help "the revision the run's branch starts from")
    <*> option auto (long "steps" <> metavar "N" <> value 60 <> showDefault <> help "stop after this many steps")
    <*> switch (long "read-only" <> help "offer no edits: explore and answer")
    <*> switch (long "in-place" <> help "work in the project directory itself, without git; for a directory that is not a repository")
    <*> oracleP
    <*> optional (strOption (long "tricorder" <> metavar "PATH" <> help "the tricorder executable (default $TRICORDER, else tricorder on PATH)"))
    <*> option auto (long "build-timeout" <> metavar "SECS" <> value 3600 <> showDefault <> help "longest wait for one build and its tests")
    <*> option auto (long "settle" <> metavar "SECS" <> value 3 <> showDefault <> help "how long an unchanged build state after an edit means no rebuild was triggered")
    <*> switch (long "index" <> help "offer SearchIndex over llmq-index's store")
    <*> optional (strOption (long "db" <> metavar "CONNINFO" <> help "the index (default $OPEN_SLOP_RAG_DB, else dbname=llmq_rag)"))
    <*> optional (strOption (long "embed-at" <> metavar "ROW/BACKEND" <> help "embedding server (default $OPEN_SLOP_RAG_EMBED_AT)"))
    <*> optional (strOption (long "embed-model" <> metavar "NAME" <> help "embedding model (default $OPEN_SLOP_RAG_EMBED_MODEL)"))
    <*> many (strOption (long "under" <> metavar "PATH" <> help "SearchIndex only looks under this path; repeat for several"))
  where
    oracleP =
      flag' OracleTricorder (long "tricorder-required" <> help "fail if tricorder cannot be started")
        <|> flag' OracleNone (long "no-oracle" <> help "no builds: edits are not checked")
        <|> pure OracleAuto

main :: IO ()
main = do
  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "A local model works on a project, checked by the compiler"))
  taskText <- case (o.task, o.taskFile) of
    (Just t, _) -> pure (T.pack t)
    (_, Just f) -> TIO.readFile f
    _ -> die' "give the task with --task TEXT or --task-file FILE"
  when (T.null (T.strip taskText)) (die' "the task is empty")

  client <- newClient
  cat <- catalogue o
  at <- setting o.chatAt ["OPEN_SLOP_AGENT_CHAT_AT", "OPEN_SLOP_RAG_CHAT_AT"] Nothing
  modelName <- T.pack <$> setting o.model ["OPEN_SLOP_AGENT_MODEL", "OPEN_SLOP_RAG_CHAT_MODEL"] Nothing
  (lan, ep, b) <- lanServer cat at
  when (b.engine == HailoOllama) (die' (endpointId ep <> " is hailo-ollama, which cannot constrain an answer to a schema; use a cpu or llamacpp endpoint"))
  cap <- capacityOf client cat ep b modelName
  say ("model " <> endpointId ep <> "/" <> modelName <> ": " <> describeCapacity cap)

  stamp <- formatTime defaultTimeLocale "%Y-%m-%d-%H%M%S" <$> getZonedTime
  stateHome <- getXdgDirectory XdgState "llmq-agent"
  let runDir = stateHome </> stamp
      runName = T.pack stamp
  createDirectoryIfMissing True runDir

  projectDir <- makeAbsolute o.project
  (rootDir, checkout) <-
    if o.inPlace
      then pure (projectDir, Nothing)
      else
        Git.topLevel projectDir >>= \case
          Left e -> die' ("the project is not in a git repository (" <> e <> "); use --in-place to work without one")
          Right top -> do
            dirty <- Git.dirtyFiles top
            unless (null dirty) (say (T.pack (show (length dirty)) <> " uncommitted changes in your checkout are not in the run's worktree; commit them first if the task needs them"))
            let wt = runDir </> "worktree"
                branchName = "llmq-agent/" <> runName
            c <- Git.addWorktree top wt branchName (T.pack o.from) >>= either die' pure
            say ("working on branch " <> branchName <> " in " <> T.pack wt)
            pure (wt </> makeRelative top projectDir, Just c)
  ws <- openWorkspace rootDir >>= either die' pure

  tricorderPath <- case o.tricorder of
    Just p -> pure (Just p)
    Nothing ->
      lookupEnv "TRICORDER" >>= \case
        Just p | not (null p) -> pure (Just p)
        _ -> findExecutable "tricorder"
  let tconf p = TricorderConfig {executable = p, root = workspaceRoot ws, buildTimeout = o.buildTimeout, settleSeconds = o.settle}
  tc <- case (o.oracle, tricorderPath) of
    (OracleNone, _) -> pure Nothing
    (OracleTricorder, Nothing) -> die' "tricorder is not on PATH; pass --tricorder PATH"
    (OracleAuto, Nothing) -> say "tricorder is not on PATH: edits will not be checked by the compiler" >> pure Nothing
    (_, Just p) -> do
      r <- Tricorder.start (tconf p)
      case (r, o.oracle) of
        (Left e, OracleTricorder) -> die' ("tricorder would not start: " <> e)
        (Left e, _) -> say ("tricorder would not start (" <> e <> "): edits will not be checked") >> pure Nothing
        (Right (), _) -> pure (Just (tconf p))

  search <-
    if o.index
      then Just <$> indexSearch o client cat
      else pure Nothing

  let kinds =
        [ k
        | k <- allKinds
        , k /= KSearchIndex || isJust search
        , k /= KLookupSource || isJust tc
        , k /= KCheck || isJust tc
        , not (o.readOnly && k `elem` [KReplaceText, KWriteFile])
        ]

  capRef <- newIORef cap
  let logFile = runDir </> "steps.jsonl"
      transcript = runDir </> "transcript.md"
      record v = BL.appendFile logFile (encode v <> "\n")
      sayRun t = say t >> TIO.appendFile transcript (t <> "\n")
      commitStep n msg = forM_ checkout \c ->
        Git.commitAll c ("llmq-agent step " <> T.pack (show n) <> ": " <> msg) >>= \case
          Left e -> say ("could not commit step " <> T.pack (show n) <> ": " <> e)
          Right _ -> pure ()
      cleanup = do
        forM_ tc Tricorder.stop
        forM_ checkout \c -> Git.removeWorktree c >>= either (\e -> say ("the worktree was not removed: " <> e)) pure

  TIO.writeFile transcript ("# llmq-agent " <> runName <> "\n\nTask:\n\n" <> taskText <> "\n\n")

  ending <-
    ( do
        initial <- case tc of
          Nothing -> pure Nothing
          Just t -> do
            say "waiting for the first build"
            Tricorder.current t >>= \case
              Left e -> say ("the first build could not be read: " <> e) >> pure Nothing
              Right rep -> pure (Just rep)
        listing <- either id T.unlines <$> listDirectory' (workspaceRoot ws)
        let budget = promptCharsWithin cap 256 o.maxWait
            opening =
              "The project root contains:\n"
                <> listing
                <> maybe "\nThere is no build oracle in this run; edits are not checked.\n" (\rep -> "\nThe build before any change:\n" <> renderReport (budget `div` 4) rep <> "\n") initial
        runAgent
          Agent
            { client
            , chat = Chat {server = lan, engine = b.engine, model = modelName}
            , capacity = capRef
            , maxWait = o.maxWait
            , workspace = ws
            , kinds
            , maxSteps = o.steps
            , currentBuild = Tricorder.current <$> tc
            , buildAfter = Tricorder.afterEdit <$> tc
            , lookupSource = Tricorder.lookupSource <$> tc
            , searchIndex = search
            , commitEdit = commitStep
            , logStep = record
            , note = sayRun
            }
          taskText
          opening
          initial
    )
      `finally` cleanup

  BL.writeFile (runDir </> "result.json") (encode (endingJson ending))
  moved <- maybe (pure False) Git.changed checkout
  stat <- if moved then maybe (pure "") Git.diffStat checkout else pure ""
  case ending of
    Finished summary -> do
      TIO.putStrLn summary
      TIO.appendFile transcript ("\nFinished:\n\n" <> summary <> "\n")
    OutOfSteps -> say ("stopped after " <> T.pack (show o.steps) <> " steps without finishing")
    Stuck why -> say ("stopped: " <> why)
    ModelFailed why -> say ("the model's server failed: " <> why)
  forM_ checkout \c ->
    if moved
      then do
        unless (T.null (T.strip stat)) (TIO.hPutStr stderr stat)
        say ("the changes are on branch " <> c.branch <> "; review with: git diff " <> T.take 12 c.base <> " " <> c.branch)
      else do
        Git.deleteBranch c
        say "no changes were made; the run's branch was removed"
  say ("the run's log is in " <> T.pack runDir)
  exitWith case ending of
    Finished _ -> ExitSuccess
    ModelFailed _ -> ExitFailure 1
    _ -> ExitFailure 2
  where
    endingJson = \case
      Finished s -> object ["ending" .= ("finished" :: Text), "summary" .= s]
      OutOfSteps -> object ["ending" .= ("out-of-steps" :: Text)]
      Stuck w -> object ["ending" .= ("stuck" :: Text), "reason" .= w]
      ModelFailed w -> object ["ending" .= ("model-failed" :: Text), "reason" .= w]

-- | SearchIndex over llmq-index's store, with its embedding settings.
indexSearch :: Opts -> Client -> Catalogue -> IO (Text -> IO Text)
indexSearch o client cat = do
  conninfo <- setting o.db ["OPEN_SLOP_RAG_DB"] (Just "dbname=llmq_rag")
  r <- try @SomeException (connectStore (T.pack conninfo))
  conn <- either (\e -> die' ("cannot connect to the index at " <> T.pack conninfo <> ": " <> T.pack (show e))) pure r
  migrate conn >>= either die' pure
  at <- setting o.embedAt ["OPEN_SLOP_RAG_EMBED_AT"] Nothing
  m <- setting o.embedModel ["OPEN_SLOP_RAG_EMBED_MODEL"] Nothing
  (lan, _, b) <- lanServer cat at
  e <- either die' pure (embedder lan b.engine (T.pack m))
  scope <- traverse (fmap T.pack . makeAbsolute) o.under
  pure \q ->
    retrieve client conn e Retrieval {depth = 40, limit = 80, scope} q >>= \case
      Left err -> pure ("the search failed: " <> err)
      Right found -> pure case relevant found of
        [] -> "nothing in the index matches"
        hits ->
          T.intercalate
            "\n\n"
            [ h.path <> ":" <> tshow h.lineFrom <> "-" <> tshow h.lineTo <> (if T.null h.heading then "" else " (" <> h.heading <> ")") <> "\n" <> h.body
            | h <- hits
            ]

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-agent: " <>)

die' :: Text -> IO a
die' t = say t >> exitWith (ExitFailure 1)

-- | The flag, else the first environment variable set, else the fallback.
setting :: Maybe String -> [String] -> Maybe String -> IO String
setting given vars fallback = case given of
  Just v -> pure v
  Nothing -> go vars
  where
    go [] = maybe (die' ("pass the flag or set " <> T.intercalate " or " (map T.pack vars))) pure fallback
    go (v : vs) =
      lookupEnv v >>= \case
        Just x | not (null x) -> pure x
        _ -> go vs

catalogue :: Opts -> IO Catalogue
catalogue o = do
  path <- setting o.catalogueFile ["OPEN_SLOP_CATALOGUE"] Nothing
  loadCatalogue path >>= either (die' . T.pack) (pure . fst)

lanServer :: Catalogue -> String -> IO (Lan, Endpoint, Backend)
lanServer cat wanted =
  case [ep | ep <- cat.endpoints, endpointId ep == T.pack wanted] of
    [] -> die' (T.pack wanted <> " is not an endpoint in the catalogue; known: " <> T.intercalate ", " (map endpointId cat.endpoints))
    (ep : _) -> do
      lan <- either die' pure (onLan ep)
      b <- maybe (die' ("no backend " <> ep.backend <> " in the catalogue")) pure (Map.lookup ep.backend cat.backends)
      pure (lan, ep, b)

-- | The same rule llmq-index uses: the server's window within the
-- catalogue's limit, and what llmq-bench measured.
capacityOf :: Client -> Catalogue -> Endpoint -> Backend -> Text -> IO Capacity
capacityOf client cat ep b m = do
  served <- probeWindow client b.engine ep.url m
  measured <- try @SomeException (measuredPath >>= readMeasured)
  let entry = case measured of
        Right (Right doc) -> measuredEntry doc ep.backend m
        _ -> Nothing
  pure (capacityFor b (lookupModel cat ep.backend m) entry served)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
