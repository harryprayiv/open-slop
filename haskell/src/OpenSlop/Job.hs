-- | A job on disk, and the state of each of its parts.
--
-- Layout under the state root:
--
-- @
--   <id>/meta.json          model, budget, sizes, creation time
--   <id>/input.txt          the input as received
--   <id>/instruction.txt
--   <id>/manifest.json      one entry per part: index, bytes, continues, starts
--   <id>/chunks/NNNN.txt
--   <id>/parts/NNNN.md      exists only when the part finished
--   <id>/parts/NNNN.json    its stats
--   <id>/failed/NNNN.*      raw response and request of a failed attempt
--   <id>/output.md          assembled, when every part exists
--   <id>/lock               flock, held by the running client
-- @
--
-- A part is 'Done' when its .md exists. The .md is renamed into place last,
-- so a crash before the rename leaves 'Pending' and the part runs again from
-- the start. The id hashes model, budget, instruction and input, so the same
-- command names the same job and a changed catalogue starts a new one.
module OpenSlop.Job
  ( JobId (..)
  , Meta (..)
  , ManifestEntry (..)
  , PartState (..)
  , Job (..)
  , jobId
  , create
  , open
  , partState
  , writePart
  , recordFailure
  , assemble
  , withJobLock
  , listJobs
  ) where

import Control.Exception (bracket)
import Control.Monad (forM, unless, when)
import Data.Aeson (FromJSON (..), ToJSON, eitherDecodeFileStrict, encodeFile)
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import OpenSlop.Catalogue (Budget (..))
import OpenSlop.Chunk (Mode (..), Part (..), chunkWith)
import OpenSlop.Stats (Stats)
import System.Directory
import System.FileLock (SharedExclusive (Exclusive), tryLockFile, unlockFile)
import System.FilePath ((</>))
import Text.Printf (printf)
import Crypto.Hash.SHA256 qualified as SHA256

newtype JobId = JobId Text
  deriving stock (Show, Eq)
  deriving newtype (ToJSON, FromJSON)

data Meta = Meta
  { id :: JobId
  , model :: Text
  -- ^ row/backend/name
  , source :: Text
  , budget :: Budget
  , perFile :: Bool
  -- ^ one file per part; absent in jobs made before 2026-09-20, read as False
  , inputBytes :: Int
  , parts :: Int
  , created :: UTCTime
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON Meta where
  parseJSON = Aeson.withObject "Meta" \o ->
    Meta
      <$> o Aeson..: "id"
      <*> o Aeson..: "model"
      <*> o Aeson..: "source"
      <*> o Aeson..: "budget"
      <*> (fromMaybe False <$> o Aeson..:? "perFile")
      <*> o Aeson..: "inputBytes"
      <*> o Aeson..: "parts"
      <*> o Aeson..: "created"

data ManifestEntry = ManifestEntry
  { index :: Int
  , bytes :: Int
  , continues :: Maybe Text
  , starts :: [Text]
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data PartState = Pending | Done Stats
  deriving stock (Show)

data Job = Job
  { dir :: FilePath
  , meta :: Meta
  , manifest :: [ManifestEntry]
  , instruction :: Text
  }
  deriving stock (Show)

-- | Twelve hex characters of sha256 over everything that shapes the parts.
jobId :: Text -> Budget -> Bool -> Text -> Text -> JobId
jobId model budget perFile instruction input =
  JobId
    . T.take 12
    . TE.decodeUtf8
    . B16.encode
    . SHA256.hash
    $ TE.encodeUtf8
      ( T.intercalate
          "\n"
          [ model
          , T.pack (show budget.chunkBytes)
          , T.pack (show budget.ctx)
          , T.pack (show budget.predict)
          , T.pack (show budget.temperature)
          , if perFile then "per-file" else "packed"
          , TE.decodeUtf8 (B16.encode (SHA256.hash (TE.encodeUtf8 instruction)))
          , TE.decodeUtf8 (B16.encode (SHA256.hash (TE.encodeUtf8 input)))
          ]
      )

tag :: Int -> String
tag = printf "%04d"

-- | Create the job directory, or open it if it already exists for this id.
-- Built under a temporary name and renamed into place, so a half-written
-- job never looks like a whole one.
create :: FilePath -> Text -> Text -> Budget -> Bool -> Text -> Text -> IO (Job, Bool)
create root model source budget perFile instruction input = do
  let JobId jid = jobId model budget perFile instruction input
      dir = root </> T.unpack jid
  exists <- doesFileExist (dir </> "meta.json")
  if exists
    then (,True) <$> open root (JobId jid)
    else do
      let build = dir <> ".building"
      removePathForcibly build
      createDirectoryIfMissing True (build </> "chunks")
      createDirectoryIfMissing True (build </> "parts")
      createDirectoryIfMissing True (build </> "failed")
      TIO.writeFile (build </> "input.txt") input
      TIO.writeFile (build </> "instruction.txt") instruction
      let parts = chunkWith (if perFile then PerFile else Packed) budget.chunkBytes input
      when (null parts) (fail "the chunker produced no parts")
      mapM_ (\p -> TIO.writeFile (build </> "chunks" </> (tag p.index <> ".txt")) p.body) parts
      let manifest = [ManifestEntry {index = p.index, bytes = p.bytes, continues = p.continues, starts = p.starts} | p <- parts]
      encodeFile (build </> "manifest.json") manifest
      now <- getCurrentTime
      let meta =
            Meta
              { id = JobId jid
              , model
              , source
              , budget
              , perFile
              , inputBytes = B.length (TE.encodeUtf8 input)
              , parts = length parts
              , created = now
              }
      encodeFile (build </> "meta.json") meta
      renameDirectory build dir
      pure (Job {dir, meta, manifest, instruction}, False)

open :: FilePath -> JobId -> IO Job
open root (JobId jid) = do
  let dir = root </> T.unpack jid
  meta <- eitherDecodeFileStrict (dir </> "meta.json") >>= either fail pure
  manifest <- eitherDecodeFileStrict (dir </> "manifest.json") >>= either fail pure
  instruction <- TIO.readFile (dir </> "instruction.txt")
  pure Job {dir, meta, manifest, instruction}

partState :: Job -> Int -> IO PartState
partState job ix = do
  let md = job.dir </> "parts" </> (tag ix <> ".md")
      js = job.dir </> "parts" </> (tag ix <> ".json")
  done <- doesFileExist md
  if not done
    then pure Pending
    else eitherDecodeFileStrict js >>= either fail (pure . Done)

-- | Stats first, then the text renamed into place, so the .md existing means
-- both are there.
writePart :: Job -> Int -> Text -> Stats -> IO ()
writePart job ix text stats = do
  let base = job.dir </> "parts" </> tag ix
  encodeFile (base <> ".json") stats
  TIO.writeFile (base <> ".md.partial") text
  renameFile (base <> ".md.partial") (base <> ".md")

recordFailure :: Job -> Int -> B.ByteString -> B.ByteString -> IO ()
recordFailure job ix rawResponse requestBody = do
  let base = job.dir </> "failed" </> tag ix
  createDirectoryIfMissing True (job.dir </> "failed")
  B.writeFile (base <> ".raw") rawResponse
  B.writeFile (base <> ".body.json") requestBody

assemble :: Job -> IO FilePath
assemble job = do
  let total = job.meta.parts
      JobId jid = job.meta.id
  bodies <- forM [1 .. total] \ix -> do
    st <- partState job ix
    case st of
      Pending -> fail ("part " <> show ix <> " is not finished")
      Done _ -> TIO.readFile (job.dir </> "parts" </> (tag ix <> ".md"))
  let out =
        T.concat
          ( ("<!-- llmq job " <> jid <> ": " <> job.meta.model <> ", " <> T.pack (show total) <> " parts -->\n")
              : [ "\n<!-- part " <> T.pack (show ix) <> " of " <> T.pack (show total) <> " -->\n\n" <> b <> "\n"
                | (ix, b) <- zip [1 :: Int ..] bodies
                ]
          )
  TIO.writeFile (job.dir </> ".output.md.partial") out
  renameFile (job.dir </> ".output.md.partial") (job.dir </> "output.md")
  pure (job.dir </> "output.md")

-- | One runner per job. Returns Nothing without running the action when
-- another process holds the lock.
withJobLock :: Job -> IO a -> IO (Maybe a)
withJobLock job act = do
  m <- tryLockFile (job.dir </> "lock") Exclusive
  case m of
    Nothing -> pure Nothing
    Just l -> Just <$> bracket (pure l) unlockFile (const act)

-- | Every job under the root, with how many parts are finished.
listJobs :: FilePath -> IO [(Meta, Int, Bool)]
listJobs root = do
  exists <- doesDirectoryExist root
  unless exists (pure ())
  names <- if exists then listDirectory root else pure []
  fmap concat $ forM names \n -> do
    let dir = root </> n
    isJob <- doesFileExist (dir </> "meta.json")
    if not isJob
      then pure []
      else do
        meta <- eitherDecodeFileStrict (dir </> "meta.json") >>= either fail pure
        finished <- length . filter ((== ".md") . takeExtension') <$> listDirectory (dir </> "parts")
        complete <- doesFileExist (dir </> "output.md")
        pure [(meta, finished, complete)]
  where
    takeExtension' s = reverse (take 3 (reverse s))