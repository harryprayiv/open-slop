-- | Probes for suspected defects. Each test asserts the behaviour the spec
-- (open-slop.allium) requires; a failure is evidence for the matching
-- issue. O-numbers match the spec's comments.
module Probe (probes) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (SomeException, try)
import Data.Either (isLeft, isRight)
import OpenSlop.Agent.Workspace (openWorkspace, resolve)
import OpenSlop.Capacity (Capacity (..), capacityFor)
import OpenSlop.Catalogue
import OpenSlop.Job qualified as Job
import System.Directory (createDirectoryIfMissing, createFileLink, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

probes :: TestTree
probes =
  testGroup
    "probes"
    [ testCase "O1 a model's catalogue ctx caps the window on hailo-ollama" hailoModelCap
    , testCase "O2 a dangling symbolic link does not lead a write outside the project" danglingLink
    , testCase "O3 two runs creating the same job at once both get a usable job" concurrentCreate
    ]

hailo :: Backend
hailo =
  Backend
    { engine = HailoOllama
    , port = 0
    , streams = True
    , acceptsOptions = True
    , ctx = 2048
    , predict = 768
    , promptOverhead = 256
    , charsPerToken = 2.8
    , temperature = Nothing
    , blurb = ""
    }

-- | llama3.2:3b's HEF holds 896 tokens on the Hailo-10H, so its catalogue
-- entry says ctx 896; probeWindow reports 2048 for every hailo model.
hailoModelCap :: Assertion
hailoModelCap = do
  let small = Model {summary = "", docFit = Unknown, ctx = Just 896, predict = Nothing, tokPerSec = Nothing, licence = "", blurb = ""}
  (capacityFor hailo (Just small) Nothing (Just 2048)).window @?= 896

-- | doesPathExist is False for a dangling link, so resolve anchors on the
-- link's directory, which is inside, and passes the path; writing it
-- creates the link's target outside the project.
danglingLink :: Assertion
danglingLink = do
  tmp <- getTemporaryDirectory
  let base = tmp </> "open-slop-probe-ws"
  removePathForcibly base
  createDirectoryIfMissing True (base </> "proj")
  createDirectoryIfMissing True (base </> "outside")
  createFileLink (base </> "outside" </> "planted.sh") (base </> "proj" </> "notes.txt")
  ws <- either (assertFailure . show) pure =<< openWorkspace (base </> "proj")
  r <- resolve ws "notes.txt"
  removePathForcibly base
  assertBool "a path through a dangling link to outside is refused" (isLeft r)

-- | create checks for meta.json, then builds under <id>.building, which it
-- first removes. Two runs of the same command at once remove each other's
-- half-built directory, and the second rename finds the job already there.
concurrentCreate :: Assertion
concurrentCreate = do
  tmp <- getTemporaryDirectory
  let root = tmp </> "open-slop-probe-jobs"
      budget = Budget {ctx = 2048, predict = 512, chunkBytes = 64, bytesPerToken = 3.0, temperature = Nothing}
      input = mconcat (replicate 2000 "line of input text\n")
  removePathForcibly root
  createDirectoryIfMissing True root
  results <-
    mapConcurrently
      (const (try @SomeException (Job.create root "row/backend/model" "probe" budget False "summarise" input)))
      [1 :: Int .. 8]
  removePathForcibly root
  assertBool ("every concurrent create succeeds: " <> show [either show (const "ok") r | r <- results]) (all isRight results)