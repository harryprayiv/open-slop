-- | Walking directories and writing what is in them into the index.
--
-- Part of llmq-index; Main describes the program. A file whose content hash
-- and vectors for the embedding model are already stored is skipped
-- without being read past the hash. A changed file is replaced whole, in
-- one transaction, so a crash mid-run leaves every file either at its old
-- state or its new one. Files that have gone from a root are removed at the
-- end of a run over it.
module Ingest
  ( IngestOpts (..)
  , ingestRoot
  ) where

import Control.Monad (foldM, unless)
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
import OpenSlop.Rag.Split (SplitConfig (..), defaultSplit, embedText, split)
import OpenSlop.Rag.Store (Connection, DocState (..), Document (..), docState, ensureIndex, removeMissing, replaceDocument)
import System.Directory (canonicalizePath, doesDirectoryExist, getFileSize, listDirectory, pathIsSymbolicLink)
import System.FilePath ((</>))
import System.IO (stderr)

data IngestOpts = IngestOpts
  { roots :: [FilePath]
  , batch :: Int
  , maxBytes :: Integer
  , target :: Int
  , dryRun :: Bool
  }

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

-- | Every regular file under a directory, not following symlinks, skipping
-- the directories 'skipDir' names, in sorted order.
walk :: FilePath -> IO [FilePath]
walk dir = do
  names <- sort <$> listDirectory dir
  concat
    <$> traverse
      ( \n -> do
          let p = dir </> n
          link <- pathIsSymbolicLink p
          isDir <- doesDirectoryExist p
          if
            | link -> pure []
            | isDir -> if skipDir n then pure [] else walk p
            | otherwise -> pure [p]
      )
      names

data Tally = Tally {fresh :: Int, written :: Int, skipped :: Int, failed :: Int, chunks :: Int}

ingestRoot :: Client -> Connection -> Embedder -> IngestOpts -> FilePath -> IO ()
ingestRoot client conn e o dir = do
  root <- canonicalizePath dir
  files <- walk root
  say (T.pack root <> ": " <> T.pack (show (length files)) <> " files")
  indexed <- newIORef False
  seen <- newIORef []
  let cfg = defaultSplit {target = o.target, hardLimit = max o.target (o.target * 3 `div` 2)}
  t <-
    foldM
      ( \t path -> case classify path of
          Nothing -> pure t {skipped = t.skipped + 1}
          Just kind -> do
            size <- getFileSize path
            if size > o.maxBytes
              then do
                say ("skip " <> T.pack path <> ": " <> T.pack (show size) <> " bytes")
                pure t {skipped = t.skipped + 1}
              else do
                raw <- B.readFile path
                let sha = TE.decodeUtf8 (B16.encode (SHA256.hash raw))
                    p = T.pack path
                modifyIORef' seen (p :)
                st <- if o.dryRun then pure Changed else docState conn e.model p sha
                if st == Fresh
                  then pure t {fresh = t.fresh + 1}
                  else
                    extract kind path raw >>= \case
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
      )
      (Tally 0 0 0 0 0)
      files
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
        <> T.pack (show removed)
        <> " removed"
    )
  where
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