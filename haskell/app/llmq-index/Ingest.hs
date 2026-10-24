-- | Walking directories and writing what is in them into the index.
--
-- Part of llmq-index; Main describes the program. A file whose content hash
-- and vectors for the embedding model are already stored is skipped
-- without being read past the hash. A changed file is replaced whole, in
-- one transaction, so a crash mid-run leaves every file either at its old
-- state or its new one. Files that have gone from a root, or that are now
-- excluded (see "OpenSlop.Rag.Exclude"), are removed at the end of a run
-- over it. A root that still keeps .llmqignore or .llmqchase at its top,
-- not in .inference, is refused before anything is read or removed.
--
-- A root with a .inference/.llmqchase file also gets chase bundles of its code, made
-- in the same run from the same tree and indexed beside the files; see
-- Bundles.
--
-- The walk does not go into .inference, but the Allium specifications kept
-- there (.inference/*.allium) are indexed with the files, under their own
-- paths: a specification says what the code is meant to do and where it
-- differs, which is context a question about the code needs. Nothing else
-- in .inference is indexed: the bundles kept there are old runs, replaced
-- by the ones made in this run, and the annotations files are already in
-- those bundles.
module Ingest
  ( IngestOpts (..)
  , ingestRoot
  ) where

import Bundles (ChaseRun (..), bundleDir, bundleName, makeBundle, readChaseRuns)
import Control.Monad (filterM, foldM, forM, forM_, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as B16
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Extract (classify, extract, kindName, skipDir, structureOf)
import OpenSlop.Http (Client)
import OpenSlop.Rag.Embed (Embedder (..), Purpose (ForDocument), embed)
import OpenSlop.Rag.Exclude (Pattern, excluded, ignoreFile, inferenceDir, legacyFiles, parsePatterns, readIgnoreFile, secretKind)
import OpenSlop.Rag.Split (SplitConfig (..), defaultSplit, embedText, split)
import OpenSlop.Rag.Store (Connection, DocState (..), Document (..), docState, ensureIndex, removeMissing, replaceDocument)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getFileSize, listDirectory, pathIsSymbolicLink)
import System.FilePath (takeExtension, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

data IngestOpts = IngestOpts
  { roots :: [FilePath]
  , batch :: Int
  , maxBytes :: Integer
  , target :: Int
  , dryRun :: Bool
  , excludes :: [Text]
  -- ^ patterns from --exclude, added to the root's .inference/.llmqignore
  }

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

-- | Every regular file under a directory, not following symlinks, skipping
-- the directories 'skipDir' names and whatever the patterns exclude, in
-- sorted order, with how many paths the patterns excluded. An excluded
-- directory counts once and is not walked into.
walk :: [Pattern] -> FilePath -> IO ([FilePath], Int)
walk patterns root = go []
  where
    go rel = do
      names <- sort <$> listDirectory (foldl (</>) root (map T.unpack rel))
      results <-
        traverse
          ( \n -> do
              let relPath = rel <> [T.pack n]
                  p = foldl (</>) root (map T.unpack relPath)
              link <- pathIsSymbolicLink p
              isDir <- doesDirectoryExist p
              if
                | link -> pure ([], 0)
                | isDir && skipDir n -> pure ([], 0)
                | excluded patterns relPath isDir -> pure ([], 1)
                | isDir -> go relPath
                | otherwise -> pure ([p], 0)
          )
          names
      pure (concatMap fst results, sum (map snd results))

-- | The Allium specifications in a root's .inference directory, as paths,
-- with any the patterns exclude left out. Links are not followed.
specFiles :: [Pattern] -> FilePath -> IO [FilePath]
specFiles patterns root = do
  let dir = root </> inferenceDir
  there <- doesDirectoryExist dir
  names <- if there then sort <$> listDirectory dir else pure []
  fmap concat . forM names $ \n -> do
    let p = dir </> n
    link <- pathIsSymbolicLink p
    isFile <- doesFileExist p
    pure
      [ p
      | not link
      , isFile
      , takeExtension n == ".allium"
      , not (excluded patterns [T.pack inferenceDir, T.pack n] False)
      ]

-- | One thing to index: where to read it, and the path it is stored
-- under. For a file those are the same; for a bundle the first is a
-- temporary file and the second ROOT/.inference/chase/NAME.chase.
data Entry = Entry {readFrom :: FilePath, storedAs :: FilePath}

-- | The bundles a root's .inference/.llmqchase asks for, made into the directory
-- given. A run chase cannot make is reported and has no entry, so its
-- earlier bundle is removed at the end of the run instead of describing
-- code that has since changed.
chaseBundles :: FilePath -> FilePath -> IO [Entry]
chaseBundles root tmp =
  readChaseRuns root >>= \case
    Left err -> say ("no chase bundles: " <> err) >> pure []
    Right runs -> fmap concat . forM runs $ \r -> do
      let out = tmp </> bundleName r
      makeBundle root out r >>= \case
        Left why -> do
          say ("no bundle of " <> T.pack r.src <> " (" <> why <> "); an earlier one leaves the index")
          pure []
        Right warnings -> do
          forM_ warnings \w -> say ("chase, " <> T.pack r.src <> ": " <> w)
          pure [Entry {readFrom = out, storedAs = root </> bundleDir </> bundleName r}]

data Tally = Tally {fresh :: Int, written :: Int, skipped :: Int, failed :: Int, secrets :: Int, chunks :: Int}

ingestRoot :: Client -> Connection -> Embedder -> IngestOpts -> FilePath -> IO ()
ingestRoot client conn e o dir = do
  root <- canonicalizePath dir
  stale <- filterM (\(old, _) -> doesFileExist (root </> old)) legacyFiles
  if null stale
    then ingestLaidOut client conn e o root
    else
      forM_ stale \(old, new) ->
        say
          ( T.pack root
              <> ": not ingested: "
              <> T.pack old
              <> " is read from "
              <> T.pack new
              <> " now; move it there and run again"
          )

ingestLaidOut :: Client -> Connection -> Embedder -> IngestOpts -> FilePath -> IO ()
ingestLaidOut client conn e o root = do
  fromFile <- readIgnoreFile root
  let patterns = fromFile <> parsePatterns o.excludes
  (walked, excludedPaths) <- walk patterns root
  specs <- specFiles patterns root
  let files = walked <> specs
  say
    ( T.pack root
        <> ": "
        <> T.pack (show (length files))
        <> " files, "
        <> T.pack (show excludedPaths)
        <> " paths excluded by "
        <> T.pack (show (length fromFile))
        <> " patterns in "
        <> T.pack ignoreFile
        <> " and "
        <> T.pack (show (length o.excludes))
        <> " from --exclude, "
        <> T.pack (show (length specs))
        <> " specifications from "
        <> T.pack inferenceDir
    )
  -- The bundles are read inside the temporary directory's lifetime, so
  -- everything is indexed within it.
  withSystemTempDirectory "llmq-chase" \tmp -> do
    bundles <- chaseBundles root tmp
    unless (null bundles) (say (T.pack root <> ": " <> T.pack (show (length bundles)) <> " chase bundles made"))
    indexAll ([Entry f f | f <- files] <> bundles)
  where
    cfg = defaultSplit {target = o.target, hardLimit = max o.target (o.target * 3 `div` 2)}

    indexAll entries = do
      indexed <- newIORef False
      seen <- newIORef []
      t <- foldM (indexOne indexed seen) (Tally 0 0 0 0 0 0) entries
      removed <-
        if o.dryRun
          then pure (0 :: Int64)
          else readIORef seen >>= removeMissing conn (T.pack root)
      say
        ( T.pack root
            <> ": "
            <> T.pack (show t.written)
            <> " written ("
            <> T.pack (show t.chunks)
            <> " chunks), "
            <> T.pack (show t.fresh)
            <> " unchanged, "
            <> T.pack (show t.skipped)
            <> " not indexable, "
            <> T.pack (show t.failed)
            <> " failed, "
            <> T.pack (show t.secrets)
            <> " secrets left out, "
            <> T.pack (show removed)
            <> " removed"
        )

    indexOne indexed seen t entry = case classify entry.readFrom of
      Nothing -> pure t {skipped = t.skipped + 1}
      Just kind -> do
        size <- getFileSize entry.readFrom
        let p = T.pack entry.storedAs
        if size > o.maxBytes
          then do
            say ("skip " <> p <> ": " <> T.pack (show size) <> " bytes")
            pure t {skipped = t.skipped + 1}
          else do
            raw <- B.readFile entry.readFrom
            let sha = TE.decodeUtf8 (B16.encode (SHA256.hash raw))
            case secretKind raw of
              Just why -> do
                say ("never indexed, " <> why <> ": " <> p)
                pure t {secrets = t.secrets + 1}
              Nothing -> do
                modifyIORef' seen (p :)
                st <- if o.dryRun then pure Changed else docState conn e.model p sha
                if st == Fresh
                  then pure t {fresh = t.fresh + 1}
                  else
                    extract kind entry.readFrom raw >>= \case
                      Left why -> do
                        say ("skip " <> p <> ": " <> why)
                        pure t {failed = t.failed + 1}
                      Right text -> do
                        let pieces = split cfg (structureOf kind) text
                        if o.dryRun
                          then do
                            TIO.putStrLn (p <> "  " <> kindName kind <> "  " <> T.pack (show (length pieces)) <> " chunks")
                            pure t {written = t.written + 1, chunks = t.chunks + length pieces}
                          else
                            embedAll (map embedText pieces) >>= \case
                              Left why -> do
                                say ("skip " <> p <> ": " <> why)
                                pure t {failed = t.failed + 1}
                              Right vectors -> do
                                replaceDocument
                                  conn
                                  e.model
                                  Document {root = T.pack root, path = p, sha256 = sha, kind = kindName kind, bytes = fromIntegral size}
                                  pieces
                                  vectors
                                case vectors of
                                  (v : _) -> do
                                    done <- readIORef indexed
                                    unless done (ensureIndex conn e.model (length v) >> modifyIORef' indexed (const True))
                                  [] -> pure ()
                                say (p <> ": " <> T.pack (show (length pieces)) <> " chunks")
                                pure t {written = t.written + 1, chunks = t.chunks + length pieces}

    embedAll texts = go [] (chunksOf o.batch texts)
      where
        go acc [] = pure (Right (concat (reverse acc)))
        go acc (b : bs) =
          embed client e ForDocument b >>= \case
            Left err -> pure (Left err)
            Right vs -> go (vs : acc) bs
    chunksOf n xs = case splitAt (max 1 n) xs of
      ([], _) -> []
      (a, rest) -> a : chunksOf n rest