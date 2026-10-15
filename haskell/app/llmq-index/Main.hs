-- | llmq-index: keep an index of the user's files and answer questions
-- from it, without the files leaving the LAN.
--
--   llmq-index init                    create the tables
--   llmq-index ingest DIR...           walk, extract, split, embed, store
--   llmq-index search QUESTION         the hits, with scores and sources
--   llmq-index ask QUESTION            a cited answer from a chat model
--   llmq-index stats                   what the index holds
--   llmq-index prune --model M         drop one embedding model's vectors
--   llmq-index prune --root DIR        drop everything under a root
--
-- Endpoints are named as llmq shows them (row/backend) and looked up in the
-- catalogue at $OPEN_SLOP_CATALOGUE. Each is checked by
-- "OpenSlop.Rag.Locality" before any text goes to it.
--
-- Ingest is incremental. A file whose content hash and embeddings for the
-- chosen model are already stored is skipped without being read past the
-- hash. A changed file is replaced whole, in one transaction, so a crash
-- mid-run leaves every file either at its old state or its new one. Files
-- that have gone from a root are removed at the end of a run over it.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (foldM, forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as B16
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Extract (classify, extract, kindName, skipDir)
import OpenSlop.Catalogue (Backend (..), Catalogue (..), Endpoint (..), endpointId)
import OpenSlop.Http (Client, newClient)
import OpenSlop.Measured (loadCatalogue)
import OpenSlop.Rag.Embed (Embedder (..), Purpose (ForDocument), embed, embedder)
import OpenSlop.Rag.Locality (Lan, onLan)
import OpenSlop.Rag.Retrieve (Answer (..), Retrieval (..), answer, chat, retrieve)
import OpenSlop.Rag.Split (SplitConfig (..), defaultSplit, embedText, split)
import OpenSlop.Rag.Store
import Numeric (showFFloat)
import Options.Applicative
import System.Directory (canonicalizePath, doesDirectoryExist, getFileSize, listDirectory, pathIsSymbolicLink)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)

data Global = Global
  { db :: Maybe String
  , catalogueFile :: Maybe FilePath
  , embedAt :: Maybe String
  , embedModel :: Maybe String
  }

data Command
  = Init
  | Ingest IngestOpts
  | Search Text Int Int
  | Ask AskOpts
  | ShowStats
  | PruneModel Text
  | PruneRoot FilePath

data IngestOpts = IngestOpts
  { roots :: [FilePath]
  , batch :: Int
  , maxBytes :: Integer
  , target :: Int
  , dryRun :: Bool
  }

data AskOpts = AskOpts
  { question :: Text
  , chatAt :: Maybe String
  , chatModel :: Maybe String
  , ctx :: Int
  , depth :: Int
  , limit :: Int
  }

globalP :: Parser Global
globalP =
  Global
    <$> optional (strOption (long "db" <> metavar "CONNINFO" <> help "libpq connection string (default $OPEN_SLOP_RAG_DB, else dbname=llmq_rag)"))
    <*> optional (strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON (default $OPEN_SLOP_CATALOGUE)"))
    <*> optional (strOption (long "embed-at" <> metavar "ROW/BACKEND" <> help "embedding server (default $OPEN_SLOP_RAG_EMBED_AT)"))
    <*> optional (strOption (long "embed-model" <> metavar "NAME" <> help "embedding model (default $OPEN_SLOP_RAG_EMBED_MODEL)"))

commandP :: Parser Command
commandP =
  hsubparser
    ( command "init" (info (pure Init) (progDesc "Create the tables"))
        <> command "ingest" (info (Ingest <$> ingestP) (progDesc "Index the files under one or more directories"))
        <> command "search" (info searchP (progDesc "Show what a question retrieves"))
        <> command "ask" (info (Ask <$> askP) (progDesc "Answer a question from the index, with sources"))
        <> command "stats" (info (pure ShowStats) (progDesc "What the index holds"))
        <> command "prune" (info pruneP (progDesc "Drop one model's vectors or one root's documents"))
    )
  where
    ingestP =
      IngestOpts
        <$> some (strArgument (metavar "DIR..."))
        <*> option auto (long "batch" <> value 16 <> showDefault <> help "chunks per embedding request")
        <*> option auto (long "max-bytes" <> value (20 * 1024 * 1024) <> showDefault <> help "skip files larger than this")
        <*> option auto (long "chunk-chars" <> value defaultSplit.target <> showDefault <> help "characters a chunk is packed up to")
        <*> switch (long "dry-run" <> help "walk and split, print what would be embedded, write nothing")
    searchP =
      Search
        <$> (T.pack <$> strArgument (metavar "QUESTION"))
        <*> option auto (long "depth" <> value 40 <> showDefault <> help "candidates from each half of the search")
        <*> option auto (long "limit" <> value 8 <> showDefault <> help "hits shown")
    askP =
      AskOpts
        <$> (T.pack <$> strArgument (metavar "QUESTION"))
        <*> optional (strOption (long "chat-at" <> metavar "ROW/BACKEND" <> help "chat server (default $OPEN_SLOP_RAG_CHAT_AT)"))
        <*> optional (strOption (long "model" <> metavar "NAME" <> help "chat model (default $OPEN_SLOP_RAG_CHAT_MODEL)"))
        <*> option auto (long "ctx" <> value 8192 <> showDefault <> help "window asked of ollama")
        <*> option auto (long "depth" <> value 40 <> showDefault)
        <*> option auto (long "limit" <> value 6 <> showDefault <> help "sources given to the model")
    pruneP =
      (PruneModel . T.pack <$> strOption (long "model" <> metavar "NAME"))
        <|> (PruneRoot <$> strOption (long "root" <> metavar "DIR"))

main :: IO ()
main = do
  (g, cmd) <-
    execParser
      ( info
          (((,) <$> globalP <*> commandP) <**> helper)
          (fullDesc <> progDesc "Index your files on the LAN and ask questions of them")
      )
  conninfo <- setting g.db "OPEN_SLOP_RAG_DB" (Just "dbname=llmq_rag")
  r <- try @SomeException (connectStore (T.pack conninfo))
  conn <- either (\e -> die' ("cannot connect to " <> T.pack conninfo <> ": " <> T.pack (show e))) pure r
  case cmd of
    Init -> migrate conn >>= either die' (const (say "tables ready"))
    ShowStats -> do
      s <- stats conn
      TIO.putStrLn (T.pack (show s.documents) <> " documents, " <> T.pack (show s.chunks) <> " chunks")
      forM_ s.byModel \(m, d, n) -> TIO.putStrLn ("  " <> m <> " (" <> T.pack (show d) <> " dims): " <> T.pack (show n) <> " vectors")
      forM_ s.roots \(root, n) -> TIO.putStrLn ("  " <> root <> ": " <> T.pack (show n) <> " documents")
    PruneModel m -> prune conn (Left m) >>= \n -> say ("removed " <> T.pack (show n) <> " vectors")
    PruneRoot dir -> do
      root <- T.pack <$> canonicalizePath dir
      prune conn (Right root) >>= \n -> say ("removed " <> T.pack (show n) <> " documents")
    Ingest o -> do
      client <- newClient
      e <- embedderFor g
      migrate conn >>= either die' pure
      forM_ o.roots (ingestRoot client conn e o)
    Search q d l -> do
      client <- newClient
      e <- embedderFor g
      retrieve client conn e Retrieval {depth = d, limit = l} q >>= \case
        Left err -> die' err
        Right hits -> forM_ (zip [1 :: Int ..] hits) \(n, h) -> do
          TIO.putStrLn
            ( "["
                <> T.pack (show n)
                <> "] "
                <> h.path
                <> ":"
                <> T.pack (show h.lineFrom)
                <> "-"
                <> T.pack (show h.lineTo)
                <> "  score "
                <> T.pack (showFFloat (Just 4) h.score "")
                <> via h
            )
          unless (T.null h.heading) (TIO.putStrLn ("    " <> h.heading))
          TIO.putStrLn ("    " <> T.replace "\n" "\n    " (T.take 300 h.body))
    Ask o -> do
      client <- newClient
      e <- embedderFor g
      cat <- catalogue g
      at <- setting o.chatAt "OPEN_SLOP_RAG_CHAT_AT" Nothing
      model <- setting o.chatModel "OPEN_SLOP_RAG_CHAT_MODEL" Nothing
      (lan, b) <- lanServer cat at
      c <- either die' pure (chat lan b.engine (T.pack model) o.ctx)
      hits <- retrieve client conn e Retrieval {depth = o.depth, limit = o.limit} o.question >>= either die' pure
      when (null hits) (die' "nothing in the index matches that question")
      a <- answer client c o.question hits >>= either die' pure
      TIO.putStrLn a.text
      TIO.putStrLn ""
      forM_ (zip [1 :: Int ..] a.sources) \(n, h) ->
        TIO.putStrLn
          ( (if n `elem` a.cited then "* [" else "  [")
              <> T.pack (show n)
              <> "] "
              <> h.path
              <> ":"
              <> T.pack (show h.lineFrom)
              <> "-"
              <> T.pack (show h.lineTo)
              <> (if T.null h.heading then "" else "  " <> h.heading)
          )
      when (null a.cited) (say "the answer cites no source; treat it as unsupported")
      unless (null a.invented) (say ("the answer cites sources it was not given: " <> T.pack (show a.invented)))
  where
    via h = case (h.viaVector, h.viaWords) of
      (True, True) -> "  vector+words"
      (True, False) -> "  vector"
      (False, True) -> "  words"
      _ -> ""

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

die' :: Text -> IO a
die' t = say t >> exitFailure

setting :: Maybe String -> String -> Maybe String -> IO String
setting given var fallback = case given of
  Just v -> pure v
  Nothing ->
    lookupEnv var >>= \case
      Just v | not (null v) -> pure v
      _ -> maybe (die' ("pass the flag or set " <> T.pack var)) pure fallback

catalogue :: Global -> IO Catalogue
catalogue g = do
  path <- setting g.catalogueFile "OPEN_SLOP_CATALOGUE" Nothing
  loadCatalogue path >>= either (die' . T.pack) (pure . fst)

lanServer :: Catalogue -> String -> IO (Lan, Backend)
lanServer cat wanted =
  case [ep | ep <- cat.endpoints, endpointId ep == T.pack wanted] of
    [] -> die' (T.pack wanted <> " is not an endpoint in the catalogue; known: " <> T.intercalate ", " (map endpointId cat.endpoints))
    (ep : _) -> do
      lan <- either die' pure (onLan ep)
      b <- maybe (die' ("no backend " <> ep.backend <> " in the catalogue")) pure (Map.lookup ep.backend cat.backends)
      pure (lan, b)

embedderFor :: Global -> IO Embedder
embedderFor g = do
  cat <- catalogue g
  at <- setting g.embedAt "OPEN_SLOP_RAG_EMBED_AT" Nothing
  model <- setting g.embedModel "OPEN_SLOP_RAG_EMBED_MODEL" Nothing
  (lan, b) <- lanServer cat at
  either die' pure (embedder lan b.engine (T.pack model))

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
                        let pieces = split cfg text
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
