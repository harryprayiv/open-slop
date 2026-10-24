-- | llmq-index: keep an index of the user's files and answer questions
-- from it, alone or as a conversation, without the files leaving the LAN.
--
--   llmq-index init                       create the tables
--   llmq-index ingest DIR...              walk, extract, split, embed, store;
--                                         each DIR's .inference/.llmqignore
--                                         and --exclude leave paths out, and
--                                         secrets are never indexed; see
--                                         "OpenSlop.Rag.Exclude"
--   llmq-index search QUESTION            the hits, with scores and sources
--   llmq-index ask QUESTION               one cited answer, streamed
--   llmq-index chat [--session NAME]      a conversation, stored by name
--   llmq-index eval FILE                  measure retrieval and answers
--                                         against known answers; see Eval
--   llmq-index sessions                   the stored conversations
--   llmq-index docs [--under PATH]        the indexed documents
--   llmq-index forget FILE...             remove documents from the index
--   llmq-index stats                      what the index holds
--   llmq-index prune --model M            drop one embedding model's vectors
--   llmq-index prune --root DIR           drop everything under a root
--
-- Endpoints are named as llmq shows them (row/backend) and looked up in the
-- catalogue at $OPEN_SLOP_CATALOGUE. Each is checked by
-- "OpenSlop.Rag.Locality" before any text goes to it.
--
-- How much one question may carry (conversation, sources, answer) comes
-- from "OpenSlop.Capacity": the window the chat server reports within the
-- catalogue's limit, and the characters per token llmq-bench measured.
-- Sources are chosen in one of two ways. With a reranker configured
-- (--rerank-at, default $OPEN_SLOP_RAG_RERANK_AT), the best --rerank-depth
-- candidates of the hybrid search are reordered by it; see
-- "OpenSlop.Rag.Rerank". Without one, candidates are cut by similarity;
-- see "OpenSlop.Rag.Retrieve".relevant. Either way at most --sources are
-- kept, then packed into that capacity. No answer length is fixed here. --max-wait
-- limits the prompt further, by the measured prefill rate, when an answer
-- is wanted within a given time on slow hardware.
--
-- --sources defaults to 4. On 2026-10-18 all 25 answering chunks of the
-- evaluation sets were sent at 4 as at 6, and each source left out is up
-- to 2400 characters less for oracle's CPU to read before it answers; the
-- mean answer took 229 to 300 seconds at 6.
--
-- --rerank-depth defaults to 30. At 20, three of 25 answering chunks in
-- the evaluation sets were found by the search at 25th to 29th and never
-- scored; at 30 all three were kept and nothing else moved, for about 25
-- seconds more per question on oracle.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless, when)
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime)
import Converse (askOnce, converse)
import OpenSlop.Rag.Ask (Asking (..))
import Eval (EvalOpts (..), runEval)
import Ingest (IngestOpts (..), ingestRoot)
import Numeric (showFFloat)
import OpenSlop.Capacity (Capacity, capacityFor, measuredEntry, probeWindow)
import OpenSlop.Catalogue (Backend (..), Catalogue (..), Endpoint (..), endpointId, lookupModel)
import OpenSlop.Http (Client, newClient)
import OpenSlop.Measured (loadCatalogue, measuredPath, readMeasured)
import OpenSlop.Rag.Embed (Embedder (..), embedder)
import OpenSlop.Rag.Locality (Lan, onLan)
import OpenSlop.Rag.Rerank (Reranker, rerank, reranker, withinMargin)
import OpenSlop.Rag.Retrieve (Chat (..), Retrieval (..), relevanceMargin, retrieve)
import OpenSlop.Rag.Split (SplitConfig (..), defaultSplit)
import OpenSlop.Rag.Store
import Options.Applicative
import System.Directory (canonicalizePath, makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)

data Global = Global
  { db :: Maybe String
  , catalogueFile :: Maybe FilePath
  , embedAt :: Maybe String
  , embedModel :: Maybe String
  , rerankAt :: Maybe String
  , rerankModel :: Maybe String
  , noRerank :: Bool
  }

data Talk = Talk
  { chatAt :: Maybe String
  , chatModel :: Maybe String
  , maxWait :: Maybe Double
  , depth :: Int
  , sources :: Int
  , rerankDepth :: Int
  , rerankMargin :: Double
  , split :: Bool
  , under :: [FilePath]
  }

data Command
  = Init
  | Ingest IngestOpts
  | Search Text Int Int Int Double [FilePath]
  | Ask Text Talk
  | ChatCmd (Maybe Text) Talk
  | EvalCmd EvalOpts Talk
  | Sessions
  | Docs [FilePath]
  | Forget [FilePath]
  | ShowStats
  | PruneModel Text
  | PruneRoot FilePath

globalP :: Parser Global
globalP =
  Global
    <$> optional (strOption (long "db" <> metavar "CONNINFO" <> help "libpq connection string (default $OPEN_SLOP_RAG_DB, else dbname=llmq_rag)"))
    <*> optional (strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON (default $OPEN_SLOP_CATALOGUE)"))
    <*> optional (strOption (long "embed-at" <> metavar "ROW/BACKEND" <> help "embedding server (default $OPEN_SLOP_RAG_EMBED_AT)"))
    <*> optional (strOption (long "embed-model" <> metavar "NAME" <> help "embedding model (default $OPEN_SLOP_RAG_EMBED_MODEL)"))
    <*> optional (strOption (long "rerank-at" <> metavar "ROW/BACKEND" <> help "reranking llama-server (default $OPEN_SLOP_RAG_RERANK_AT; unset means no reranking)"))
    <*> optional (strOption (long "rerank-model" <> metavar "NAME" <> help "reranker's model name (default $OPEN_SLOP_RAG_RERANK_MODEL)"))
    <*> switch (long "no-rerank" <> help "choose sources by similarity even when a reranker is configured")

underP :: Parser [FilePath]
underP = many (strOption (long "under" <> metavar "PATH" <> help "only documents under this path; repeat for several"))

talkP :: Parser Talk
talkP =
  Talk
    <$> optional (strOption (long "chat-at" <> metavar "ROW/BACKEND" <> help "chat server (default $OPEN_SLOP_RAG_CHAT_AT)"))
    <*> optional (strOption (long "model" <> metavar "NAME" <> help "chat model (default $OPEN_SLOP_RAG_CHAT_MODEL)"))
    <*> optional (option auto (long "max-wait" <> metavar "SECS" <> help "keep the prompt small enough to be read within this time, at the measured prefill rate"))
    <*> option auto (long "depth" <> value 40 <> showDefault <> help "candidates from each half of the search")
    <*> option auto (long "sources" <> value 4 <> showDefault <> help "the most sources one answer is given; a small model answers worse the more it is given")
    <*> rerankDepthP
    <*> rerankMarginP
    <*> switch (long "split" <> help "have the model split a question that may ask several things, and search each part on its own")
    <*> underP

rerankMarginP :: Parser Double
rerankMarginP = option auto (long "rerank-margin" <> value 2.0 <> showDefault <> help "drop reranked candidates scoring more than this below the best")

rerankDepthP :: Parser Int
rerankDepthP = option auto (long "rerank-depth" <> value 30 <> showDefault <> help "candidates sent to the reranker; its time grows with this")

commandP :: Parser Command
commandP =
  hsubparser
    ( command "init" (info (pure Init) (progDesc "Create the tables"))
        <> command "ingest" (info (Ingest <$> ingestP) (progDesc "Index the files under one or more directories"))
        <> command "search" (info searchP (progDesc "Show what a question retrieves"))
        <> command "ask" (info (Ask <$> (T.pack <$> strArgument (metavar "QUESTION")) <*> talkP) (progDesc "Answer one question from the index, with sources"))
        <> command "chat" (info (ChatCmd <$> optional (T.pack <$> strOption (long "session" <> metavar "NAME" <> help "continue or start this conversation")) <*> talkP) (progDesc "A conversation about your files, stored by name"))
        <> command "eval" (info (EvalCmd <$> evalP <*> talkP) (progDesc "Measure retrieval and answers against questions with known answers"))
        <> command "sessions" (info (pure Sessions) (progDesc "List stored conversations"))
        <> command "docs" (info (Docs <$> underP) (progDesc "List the indexed documents"))
        <> command "forget" (info (Forget <$> some (strArgument (metavar "FILE..."))) (progDesc "Remove documents from the index"))
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
        <*> many (T.pack <$> strOption (long "exclude" <> metavar "GLOB" <> help "leave out paths matching this, as in a .llmqignore line; repeat for several"))
    searchP =
      Search
        <$> (T.pack <$> strArgument (metavar "QUESTION"))
        <*> option auto (long "depth" <> value 40 <> showDefault <> help "candidates from each half of the search")
        <*> option auto (long "limit" <> value 8 <> showDefault <> help "hits shown")
        <*> rerankDepthP
        <*> rerankMarginP
        <*> underP
    evalP =
      EvalOpts
        <$> strArgument (metavar "FILE" <> help "the evaluation, as JSON; see the Eval module")
        <*> switch (long "retrieval-only" <> help "stop before the chat model: rank, margin and packing only")
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
  migrate conn >>= either die' pure
  case cmd of
    Init -> say "tables ready"
    ShowStats -> do
      s <- stats conn
      TIO.putStrLn (T.pack (show s.documents) <> " documents, " <> T.pack (show s.chunks) <> " chunks")
      forM_ s.byModel \(m, d, n) -> TIO.putStrLn ("  " <> m <> " (" <> T.pack (show d) <> " dims): " <> T.pack (show n) <> " vectors")
      forM_ s.roots \(root, n) -> TIO.putStrLn ("  " <> root <> ": " <> T.pack (show n) <> " documents")
    PruneModel m -> prune conn (Left m) >>= \n -> say ("removed " <> T.pack (show n) <> " vectors")
    PruneRoot dir -> do
      root <- T.pack <$> canonicalizePath dir
      prune conn (Right root) >>= \n -> say ("removed " <> T.pack (show n) <> " documents")
    Sessions -> do
      ss <- listSessions conn
      when (null ss) (say "no stored conversations")
      forM_ ss \s ->
        TIO.putStrLn (s.name <> "  " <> T.pack (show s.turns) <> " turns  started " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" s.created))
    Docs scope -> do
      sc <- absolutes scope
      ds <- listDocuments conn sc
      when (null ds) (say "no documents")
      forM_ ds \d ->
        TIO.putStrLn (d.path <> "  " <> d.kind <> "  " <> T.pack (show d.bytes) <> " bytes  " <> T.pack (show d.chunks) <> " chunks  " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M" d.ingestedAt))
    Forget files -> do
      ps <- traverse (fmap T.pack . makeAbsolute) files
      forM_ ps \p -> do
        gone <- forgetDocument conn p
        say ((if gone then "forgot " else "not in the index: ") <> p)
    Ingest o -> do
      client <- newClient
      e <- embedderFor g
      forM_ o.roots (ingestRoot client conn e o)
    Search q d l rd margin scope -> do
      client <- newClient
      e <- embedderFor g
      rr <- rerankerFor g
      sc <- absolutes scope
      retrieve client conn e Retrieval {depth = d, limit = max l rd, scope = sc} q >>= \case
        Left err -> die' err
        Right found -> do
          hits <- case rr of
            Nothing -> pure (take l found)
            Just rk ->
              rerank client rk q (take rd found) >>= \case
                Left err -> die' err
                Right scored -> do
                  say ("reranked the best " <> T.pack (show (min rd (length found))) <> " of " <> T.pack (show (length found)) <> " found; shown in the reranker's order")
                  let close = length (withinMargin margin scored)
                  forM_ (zip [1 :: Int ..] (take l scored)) \(n, (h, s)) ->
                    TIO.putStrLn
                      ( "["
                          <> T.pack (show n)
                          <> "] rerank "
                          <> T.pack (showFFloat (Just 3) s "")
                          <> "  "
                          <> h.path
                          <> ":"
                          <> T.pack (show h.lineFrom)
                          <> "-"
                          <> T.pack (show h.lineTo)
                          <> (if n <= close then "" else "  (dropped by --rerank-margin)")
                      )
                  TIO.putStrLn ""
                  say "the hybrid search's own order, for comparison:"
                  pure (take l found)
          let best = if null hits then 0 else maximum (map (.similarity) hits)
          when (null hits) (say "no matches")
          forM_ (zip [1 :: Int ..] hits) \(n, h) -> do
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
                  <> "  similarity "
                  <> T.pack (showFFloat (Just 3) h.similarity "")
                  <> (if h.similarity >= best - relevanceMargin then "" else "  (dropped by relevance)")
                  <> via h
              )
            unless (T.null h.heading) (TIO.putStrLn ("    " <> h.heading))
            TIO.putStrLn ("    " <> T.replace "\n" "\n    " (T.take 300 h.body))
    Ask q t -> do
      a <- asking g conn t
      ok <- askOnce a q
      unless ok exitFailure
    EvalCmd o t -> do
      a <- asking g conn t
      ok <- runEval a o
      unless ok exitFailure
    ChatCmd session t -> do
      a <- asking g conn t
      converse a session
  where
    via h = case (h.viaVector, h.viaWords) of
      (True, True) -> "  vector+words"
      (True, False) -> "  vector"
      (False, True) -> "  words"
      _ -> ""

absolutes :: [FilePath] -> IO [Text]
absolutes = traverse (fmap T.pack . makeAbsolute)

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

lanServer :: Catalogue -> String -> IO (Lan, Endpoint, Backend)
lanServer cat wanted =
  case [ep | ep <- cat.endpoints, endpointId ep == T.pack wanted] of
    [] -> die' (T.pack wanted <> " is not an endpoint in the catalogue; known: " <> T.intercalate ", " (map endpointId cat.endpoints))
    (ep : _) -> do
      lan <- either die' pure (onLan ep)
      b <- maybe (die' ("no backend " <> ep.backend <> " in the catalogue")) pure (Map.lookup ep.backend cat.backends)
      pure (lan, ep, b)

embedderFor :: Global -> IO Embedder
embedderFor g = do
  cat <- catalogue g
  at <- setting g.embedAt "OPEN_SLOP_RAG_EMBED_AT" Nothing
  model <- setting g.embedModel "OPEN_SLOP_RAG_EMBED_MODEL" Nothing
  (lan, _, b) <- lanServer cat at
  either die' pure (embedder lan b.engine (T.pack model))

-- | The chat model's capacity: its server's window within the catalogue's
-- limit, and what llmq-bench measured about it.
capacityOf :: Client -> Catalogue -> Endpoint -> Backend -> Text -> IO Capacity
capacityOf client cat ep b model = do
  served <- probeWindow client b.engine ep.url model
  measured <- try @SomeException (measuredPath >>= readMeasured)
  let entry = case measured of
        Right (Right doc) -> measuredEntry doc ep.backend model
        _ -> Nothing
  pure (capacityFor b (lookupModel cat ep.backend model) entry served)

-- | The reranker, when one is configured and --no-rerank was not given.
-- Configuring the server without the model, or the model without the
-- server, is an error rather than a silent fallback.
rerankerFor :: Global -> IO (Maybe Reranker)
rerankerFor g
  | g.noRerank = pure Nothing
  | otherwise = do
      at <- optionalSetting g.rerankAt "OPEN_SLOP_RAG_RERANK_AT"
      model <- optionalSetting g.rerankModel "OPEN_SLOP_RAG_RERANK_MODEL"
      case (at, model) of
        (Nothing, Nothing) -> pure Nothing
        (Just w, Just m) -> do
          cat <- catalogue g
          (lan, _, b) <- lanServer cat w
          Just <$> either die' pure (reranker lan b.engine (T.pack m))
        (Just _, Nothing) -> die' "a reranker server is set but no model: pass --rerank-model or set OPEN_SLOP_RAG_RERANK_MODEL"
        (Nothing, Just _) -> die' "a reranker model is set but no server: pass --rerank-at or set OPEN_SLOP_RAG_RERANK_AT"

optionalSetting :: Maybe String -> String -> IO (Maybe String)
optionalSetting given var = case given of
  Just v -> pure (Just v)
  Nothing ->
    lookupEnv var >>= \case
      Just v | not (null v) -> pure (Just v)
      _ -> pure Nothing

asking :: Global -> Connection -> Talk -> IO Asking
asking g conn t = do
  client <- newClient
  e <- embedderFor g
  rr <- rerankerFor g
  cat <- catalogue g
  at <- setting t.chatAt "OPEN_SLOP_RAG_CHAT_AT" Nothing
  model <- T.pack <$> setting t.chatModel "OPEN_SLOP_RAG_CHAT_MODEL" Nothing
  (lan, ep, b) <- lanServer cat at
  cap <- capacityOf client cat ep b model
  capRef <- newIORef cap
  sc <- absolutes t.under >>= newIORef
  pure
    Asking
      { client
      , conn
      , embedWith = e
      , chatTo = Chat {server = lan, engine = b.engine, model}
      , capacity = capRef
      , depth = t.depth
      , sources = t.sources
      , rerankWith = rr
      , rerankDepth = t.rerankDepth
      , rerankMargin = t.rerankMargin
      , splitQuestions = t.split
      , maxWait = t.maxWait
      , scope = sc
      , note = say
      }