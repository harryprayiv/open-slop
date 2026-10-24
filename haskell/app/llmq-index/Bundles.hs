-- | chase bundles of a root's code, made fresh at every ingest.
--
-- Part of llmq-index; Main describes the program. chase (the structural
-- compressor for Haskell and PureScript, github:harryprayiv/chase) reads a
-- source tree and writes a bundle: every module's signatures, types,
-- imports and annotations, without the function bodies. A question about
-- how modules fit together can then be answered from one chunk per module
-- instead of several chunks of code.
--
-- A root asks for bundles with a .inference/.llmqchase file, committed with
-- the code, because which trees to compress and where their tests and
-- annotations are is a fact about that repository:
--
--   { "runs":
--       [ { "src": "backend/src"
--         , "tests": ["backend/test"]
--         , "annotations": ".inference/backend-chase-annotations.json" }
--       , { "src": "frontend/src" } ] }
--
-- Paths are relative to the root, not to .inference, so an annotations
-- file kept in .inference is named ".inference/NAME.json". "tests" left
-- out means chase's own search for test/, tests/ or spec/ beside the
-- source; [] means none.
-- "annotations" left out means none: chase is never left to look for an
-- annotations file, because it looks in its working directory and once
-- attached chase's own file to open-slop's modules (2026-10-17). A listed
-- annotations file that is missing is a warning, and the bundle is made
-- without it.
--
-- ============================================================================
-- WHY HERE AND NOT BEFOREHAND
-- ============================================================================
--
-- Until 2026-10-17 bundles were made on winsmuth by the sync script and
-- sent beside the code, and the bundles committed in the repositories were
-- left out by .llmqignore because they were old runs. Making them here,
-- from the tree being indexed, in the same run, means a bundle in the
-- index always describes the code in the index: the signatures and types
-- are exact. Only the annotations, written by hand or by a model, can
-- still be out of date, and chase's drift warnings, printed here, say
-- when one names something the code no longer has.
--
-- A bundle is stored as ROOT/.inference/chase/NAME.chase. Ingest never
-- walks into .inference, so no file in the walk has that path: the run's
-- removal of vanished files keeps the bundle, a re-run with unchanged code
-- finds the same hash and skips it, and when chase fails or a run is
-- removed from .llmqchase the old bundle is removed from the index rather
-- than left to describe code that changed.
--
-- chase is found at $OPEN_SLOP_CHASE, which the home-manager module sets
-- when programs.llmq.chase is given, or on PATH.
--
-- Unison is not covered. chase-unison reads a codebase through ucm's
-- local API, not files, so it needs a running ucm and a project and
-- branch name; a root of files has neither.
module Bundles
  ( ChaseRun (..)
  , chaseFile
  , bundleDir
  , readChaseRuns
  , bundleName
  , makeBundle
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import OpenSlop.Rag.Exclude (inferenceDir)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (proc, readProcess, setWorkingDir)

data ChaseRun = ChaseRun
  { src :: FilePath
  , tests :: Maybe [FilePath]
  -- ^ Nothing: chase's own search; Just []: none
  , annotations :: Maybe FilePath
  }
  deriving stock (Eq, Show)

instance FromJSON ChaseRun where
  parseJSON = withObject "chase run" \o -> ChaseRun <$> o .: "src" <*> o .:? "tests" <*> o .:? "annotations"

newtype Runs = Runs [ChaseRun]

instance FromJSON Runs where
  parseJSON = withObject ".llmqchase" \o -> Runs <$> o .: "runs"

-- | The chase runs file, relative to the root.
chaseFile :: FilePath
chaseFile = inferenceDir </> ".llmqchase"

-- | Where bundles are stored in the index, relative to the root.
bundleDir :: FilePath
bundleDir = inferenceDir </> "chase"

-- | The root's runs: none without a .inference/.llmqchase file, an error when the
-- file is there and is not the expected shape.
readChaseRuns :: FilePath -> IO (Either Text [ChaseRun])
readChaseRuns root = do
  let path = root </> chaseFile
  there <- doesFileExist path
  if not there
    then pure (Right [])
    else
      Aeson.eitherDecodeFileStrict path >>= \case
        Left err -> pure (Left (T.pack path <> ": " <> T.pack err))
        Right (Runs rs) -> case [n | (n, k) <- Map.toList (Map.fromListWith (+) [(bundleName r, 1 :: Int) | r <- rs]), k > 1] of
          [] -> pure (Right rs)
          dups -> pure (Left (T.pack path <> ": two runs would write the same bundle: " <> T.intercalate ", " (map T.pack dups)))

-- | The bundle's file name: the source path with / as -, so backend/src
-- becomes backend-src.chase and two runs never share a name.
bundleName :: ChaseRun -> FilePath
bundleName r = map (\c -> if c == '/' then '-' else c) (trimSlashes r.src) <> ".chase"
  where
    trimSlashes = reverse . dropWhile (== '/') . reverse . dropWhile (== '/')

-- | Run chase for one run into the given file, with the warnings it
-- printed (drift in the annotations, files it could not parse), or why
-- there is no bundle.
makeBundle :: FilePath -> FilePath -> ChaseRun -> IO (Either Text [Text])
makeBundle root out r = do
  srcThere <- doesDirectoryExist (root </> r.src)
  if not srcThere
    then pure (Left (T.pack r.src <> " is not a directory under " <> T.pack root))
    else do
      (annArgs, annWarn) <- case r.annotations of
        Nothing -> pure (["--no-annotations"], [])
        Just a -> do
          there <- doesFileExist (root </> a)
          pure
            if there
              then (["-a", root </> a], [])
              else (["--no-annotations"], [T.pack a <> " is missing; the bundle has no annotations"])
      let testArgs = case r.tests of
            Nothing -> []
            Just [] -> ["--no-tests"]
            Just ts -> ["-t", intercalate "," (map (root </>) ts)]
          args = [root </> r.src, "-o", out, "-q"] <> testArgs <> annArgs
      exe <- maybe "chase" id <$> lookupEnv "OPEN_SLOP_CHASE"
      -- Run from the root, so nothing chase looks for in its working
      -- directory can come from anywhere else.
      result <- try @SomeException (readProcess (setWorkingDir root (proc exe args)))
      pure case result of
        Left e -> Left (T.pack exe <> ": " <> T.pack (takeWhile (/= '\n') (show e)))
        Right (ExitFailure n, _, err) -> Left (T.pack exe <> " exited " <> T.pack (show n) <> ": " <> T.take 400 (lenient err))
        Right (ExitSuccess, stdoutText, err) ->
          Right (annWarn <> filter (not . T.null) (map T.strip (T.lines (lenient stdoutText <> "\n" <> lenient err))))
  where
    lenient = TE.decodeUtf8With TE.lenientDecode . BL.toStrict