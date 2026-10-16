-- | What a compiler says about a project, in one shape for every language.
--
-- An agent proposes a change; the build oracle rebuilds and reports. The
-- report is what the model reads next, so it is typed: the outcome of the
-- build, each diagnostic with its file and span, each test suite with its
-- failing cases. Haskell's oracle is tricorder ('decodeTricorder' reads its
-- `status --json`); a PureScript one over `purs ide server` returns the same
-- 'Report', so the loop does not know which compiler it is talking to.
--
-- ============================================================================
-- TRICORDER'S JSON
-- ============================================================================
--
-- `tricorder status --json` prints its BuildState with aeson's generic
-- encoding (tricorder 0.5, Tricorder.Build):
--
--   {"phase": PHASE, "buildId": N}
--   PHASE  {"tag":"Starting"}
--          {"tag":"Building","contents":[TARGETS, {"compiled","total"}]}
--          {"tag":"Failed","contents":"why the build command failed"}
--          {"tag":"PostBuilding" | "Finished","contents":[RESULT, POST]}
--   RESULT {"completedAt","duration","moduleCount","diagnostics":[DIAG]}
--   DIAG   {"severity":"error"|"warning","file","line","col","endLine",
--           "endCol","title","text"}
--   POST   {"testSuites": SUITES, "evalComments": EVALS}
--   SUITES an object keyed by target, or a list of [target, SUITE] pairs
--   SUITE  {"tag":"suite_running"|"suite_errored"|"suite_completed",
--           "contents": ...}, snake-cased
--   EVALS  {"tag":"Looking"|"NoneFound"} or {"tag":"Found","contents":
--           {"getComments":[{"file","comment":{"lineNumber","expression"},
--           "state":{"state":"pending"|"completed","output"}}]}}
--
-- The decoder is strict about the parts the loop depends on (the phase, the
-- diagnostics, whether each suite passed) and lenient about the rest, so a
-- field tricorder adds later does not break it.
module OpenSlop.Agent.Oracle
  ( Report (..)
  , Outcome (..)
  , Build (..)
  , Severity (..)
  , Diagnostic (..)
  , Suite (..)
  , SuiteResult (..)
  , Evaluation (..)
  , settled
  , errorsOf
  , clean
  , testsPass
  , acceptable
  , identity
  , renderReport
  , decodeTricorder
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict, withArray, withObject, (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

data Severity = SevError | SevWarning
  deriving stock (Eq, Ord, Show)

data Diagnostic = Diagnostic
  { severity :: Severity
  , file :: Text
  , line :: Int
  , col :: Int
  , endLine :: Int
  , endCol :: Int
  , title :: Text
  , text :: Text
  }
  deriving stock (Eq, Show)

data SuiteResult
  = SuitePassed
  | SuiteFailed [(Text, Text)] Text
  -- ^ failing cases with their details, and the suite's output
  | SuiteErrored Text
  | SuiteRunning
  deriving stock (Eq, Show)

data Suite = Suite
  { name :: Text
  , result :: SuiteResult
  }
  deriving stock (Eq, Show)

data Evaluation = Evaluation
  { file :: Text
  , line :: Int
  , expression :: Text
  , output :: Maybe Text
  -- ^ Nothing while it is still being evaluated
  }
  deriving stock (Eq, Show)

data Outcome
  = InProgress Text
  -- ^ what it is doing, for the log
  | CommandFailed Text
  -- ^ the build command itself failed: a broken cabal file, a missing
  -- dependency, GHCi would not start
  | Built Build
  deriving stock (Eq, Show)

-- | A build that compiled, with or without errors, and what ran after it.
data Build = Build
  { modules :: Int
  , diagnostics :: [Diagnostic]
  , suites :: [Suite]
  , evaluations :: [Evaluation]
  , testing :: Bool
  -- ^ tests or eval comments still running
  }
  deriving stock (Eq, Show)

data Report = Report
  { buildId :: Int
  , completedAt :: Maybe Text
  , outcome :: Outcome
  }
  deriving stock (Eq, Show)

-- | Nothing more will change until the next edit.
settled :: Report -> Bool
settled r = case r.outcome of
  InProgress _ -> False
  CommandFailed _ -> True
  Built b -> not b.testing

errorsOf :: Report -> [Diagnostic]
errorsOf r = case r.outcome of
  Built b -> filter (\d -> d.severity == SevError) b.diagnostics
  _ -> []

-- | It built, without errors.
clean :: Report -> Bool
clean r = case r.outcome of
  Built _ -> null (errorsOf r)
  _ -> False

testsPass :: Report -> Bool
testsPass r = case r.outcome of
  Built b -> all (\s -> s.result == SuitePassed) b.suites
  _ -> False

-- | What Finish after an edit requires.
acceptable :: Report -> Bool
acceptable r = settled r && clean r && testsPass r

-- | Two reports with the same identity describe the same build. The id
-- alone is not enough: tricorder restarts its count when the daemon
-- restarts, as it does after a cabal file changes.
identity :: Report -> (Int, Maybe Text)
identity r = (r.buildId, r.completedAt)

-- | The report as the model reads it, in at most the given characters.
-- Errors come first and are shown in full while room lasts; then
-- warnings by title; then the tests. What did not fit is counted, so the
-- model knows to fix what it sees and check again.
renderReport :: Int -> Report -> Text
renderReport room r = case r.outcome of
  InProgress what -> "The build is still running (" <> what <> ")."
  CommandFailed why -> clip room ("The build command failed before compiling anything:\n" <> why)
  Built Build {modules, diagnostics, suites, evaluations} ->
    let errs = [d | d <- diagnostics, d.severity == SevError]
        warns = [d | d <- diagnostics, d.severity == SevWarning]
        headline =
          "Build: "
            <> tshow modules
            <> " modules, "
            <> tshow (length errs)
            <> " errors, "
            <> tshow (length warns)
            <> " warnings."
        testsPart = renderSuites suites
        evalPart = renderEvals evaluations
        fixed = T.length headline + T.length testsPart + T.length evalPart + 4
        body = fitDiagnostics (max 0 (room - fixed)) errs warns
     in T.intercalate "\n" (filter (not . T.null) [headline, body, testsPart, evalPart])

fitDiagnostics :: Int -> [Diagnostic] -> [Diagnostic] -> Text
fitDiagnostics room errs warns = T.intercalate "\n" (go room (map full errs <> map brief warns))
  where
    full d = where_ d <> " error: " <> d.title <> "\n" <> T.stripEnd d.text
    brief d = where_ d <> " warning: " <> d.title
    where_ d = d.file <> ":" <> tshow d.line <> ":" <> tshow d.col <> "-" <> tshow d.endLine <> ":" <> tshow d.endCol
    go _ [] = []
    go left (x : xs)
      | T.length x + 1 <= left = x : go (left - T.length x - 1) xs
      | left > 200 = [T.take (left - 80) x <> "\n[cut]", omitted (length xs)]
      | otherwise = [omitted (length xs + 1)]
    omitted 0 = ""
    omitted n = "[" <> tshow n <> " more diagnostics not shown; fix these first and check again]"

renderSuites :: [Suite] -> Text
renderSuites [] = "Tests: none configured."
renderSuites ss = T.intercalate "\n" ("Tests:" : map one ss)
  where
    one s = case s.result of
      SuitePassed -> "  " <> s.name <> ": passed"
      SuiteRunning -> "  " <> s.name <> ": still running"
      SuiteErrored why -> "  " <> s.name <> ": could not run: " <> T.take 2000 why
      SuiteFailed [] out -> "  " <> s.name <> ": failed\n" <> indent (lastLines 40 out)
      SuiteFailed cases _ ->
        "  " <> s.name <> ": failed\n"
          <> T.intercalate "\n" ["    " <> d <> (if T.null det then "" else "\n" <> indent (T.take 1500 det)) | (d, det) <- cases]
    indent = T.intercalate "\n" . map ("      " <>) . T.lines
    lastLines n = T.unlines . reverse . take n . reverse . T.lines

renderEvals :: [Evaluation] -> Text
renderEvals [] = ""
renderEvals es = T.intercalate "\n" ("Eval comments:" : map one es)
  where
    one e = "  " <> e.file <> ":" <> tshow e.line <> " $> " <> e.expression <> "\n    " <> maybe "(still evaluating)" (T.replace "\n" "\n    " . T.take 2000) e.output

clip :: Int -> Text -> Text
clip n t
  | T.length t <= n = t
  | otherwise = T.take (max 0 (n - 6)) t <> "\n[cut]"

-- ---------------------------------------------------------------------------
-- tricorder

decodeTricorder :: Text -> Either Text Report
decodeTricorder raw = do
  v <- either (Left . T.pack) Right (eitherDecodeStrict (TE.encodeUtf8 raw))
  either (Left . T.pack) Right (parseEither state v)
  where
    state = withObject "build state" \o -> do
      bid <- o .: "buildId"
      phase <- o .: "phase"
      (completedAt, outcome) <- phaseP phase
      pure Report {buildId = bid, completedAt, outcome}

phaseP :: Value -> Parser (Maybe Text, Outcome)
phaseP = withObject "phase" \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "Starting" -> pure (Nothing, InProgress "starting")
    "Building" -> do
      c <- o .:? "contents"
      pure (Nothing, InProgress (maybe "building" progress c))
    "Failed" -> do
      why <- o .: "contents"
      pure (Nothing, CommandFailed why)
    "PostBuilding" -> built True =<< o .: "contents"
    "Finished" -> built False =<< o .: "contents"
    other -> fail ("unknown build phase " <> T.unpack other)
  where
    progress = \case
      Array xs | [_, Object p] <- toList xs ->
        case (KeyMap.lookup "compiled" p, KeyMap.lookup "total" p) of
          (Just (Number a), Just (Number b)) -> "compiled " <> tshow (round a :: Int) <> " of " <> tshow (round b :: Int) <> " modules"
          _ -> "building"
      _ -> "building"
    built postBuilding = withArray "result and post-build" \xs -> case toList xs of
      [res, post] -> do
        (at, modules, diagnostics) <- resultP res
        (suites, evaluations, pending) <- postP post
        let running = any (\s -> s.result == SuiteRunning) suites || pending
        pure (at, Built Build {modules, diagnostics, suites, evaluations, testing = postBuilding || running})
      _ -> fail "expected a build result and its post-build state"

resultP :: Value -> Parser (Maybe Text, Int, [Diagnostic])
resultP = withObject "build result" \o -> do
  at <- o .:? "completedAt"
  modules <- fromMaybe 0 <$> o .:? "moduleCount"
  ds <- o .: "diagnostics"
  diags <- traverse diagnosticP ds
  pure (at, modules, diags)

diagnosticP :: Value -> Parser Diagnostic
diagnosticP = withObject "diagnostic" \o -> do
  sev <- o .: "severity"
  severity <- case sev :: Text of
    "error" -> pure SevError
    "warning" -> pure SevWarning
    other -> fail ("unknown severity " <> T.unpack other)
  file <- o .: "file"
  line <- o .: "line"
  col <- o .: "col"
  endLine <- fromMaybe line <$> o .:? "endLine"
  endCol <- fromMaybe col <$> o .:? "endCol"
  title <- fromMaybe "" <$> o .:? "title"
  text <- fromMaybe "" <$> o .:? "text"
  pure Diagnostic {..}

postP :: Value -> Parser ([Suite], [Evaluation], Bool)
postP = withObject "post-build" \o -> do
  s <- o .:? "testSuites"
  suites <- maybe (pure []) suitesP s
  e <- o .:? "evalComments"
  (evals, pending) <- maybe (pure ([], False)) evalsP e
  pure (suites, evals, pending)

suitesP :: Value -> Parser [Suite]
suitesP = \case
  Object m -> traverse (\(k, v) -> Suite (Key.toText k) <$> suiteP v) (KeyMap.toList m)
  Array xs -> traverse pairP (toList xs)
  Null -> pure []
  _ -> fail "test suites must be an object or a list of pairs"
  where
    pairP = withArray "target and suite" \p -> case toList p of
      [k, v] -> Suite (targetName k) <$> suiteP v
      _ -> fail "expected a target and a suite"
    targetName = \case
      String t -> t
      other -> T.pack (show other)

suiteP :: Value -> Parser SuiteResult
suiteP = withObject "suite" \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "suite_running" -> pure SuiteRunning
    "suite_errored" -> do
      c <- o .: "contents"
      SuiteErrored <$> withObject "suite error" (\e -> fromMaybe "" <$> e .:? "message") c
    "suite_completed" -> do
      c <- o .: "contents"
      flip (withObject "suite completion") c \s -> do
        passed <- s .: "passed"
        out <- fromMaybe "" <$> s .:? "output"
        cases <- fromMaybe [] <$> s .:? "test_cases"
        failing <- mapMaybe id <$> traverse caseP cases
        pure (if passed then SuitePassed else SuiteFailed failing out)
    other -> fail ("unknown suite state " <> T.unpack other)
  where
    caseP = withObject "test case" \c -> do
      d <- c .: "description"
      oc <- c .: "outcome"
      flip (withObject "outcome") oc \x -> do
        t <- x .: "tag"
        if (t :: Text) == "failed"
          then (\det -> Just (d, fromMaybe "" det)) <$> x .:? "contents"
          else pure Nothing

evalsP :: Value -> Parser ([Evaluation], Bool)
evalsP = withObject "eval comments" \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "Looking" -> pure ([], True)
    "NoneFound" -> pure ([], False)
    "Found" -> do
      c <- o .: "contents"
      es <- withObject "comments" (.: "getComments") c
      evs <- traverse evalP es
      pure (evs, any (\e -> e.output == Nothing) evs)
    other -> fail ("unknown eval comment phase " <> T.unpack other)
  where
    evalP = withObject "evaluation" \e -> do
      file <- e .: "file"
      cm <- e .: "comment"
      (line, expression) <- withObject "comment" (\c -> (,) <$> c .: "lineNumber" <*> c .: "expression") cm
      st <- e .: "state"
      output <- flip (withObject "state") st \s -> do
        k <- s .: "state"
        if (k :: Text) == "completed" then Just . fromMaybe "" <$> s .:? "output" else pure Nothing
      pure Evaluation {..}

tshow :: (Show a) => a -> Text
tshow = T.pack . show
