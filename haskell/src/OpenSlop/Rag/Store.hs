-- | The index: documents, their chunks, and one embedding per chunk per
-- embedding model, in PostgreSQL with pgvector.
--
-- Postgres because one database answers both halves of hybrid retrieval:
-- pgvector for nearest neighbours and the built-in full-text search for
-- exact words, fused by reciprocal rank in a single query. Exact names,
-- hostnames and identifiers are common in personal files and are what
-- vector search alone misses.
--
-- Embeddings are keyed by model name and carry their dimension, and search
-- reads only the asked model's rows, so two vector spaces are never
-- compared. A document is written with the vectors of the model that
-- ingested it; re-ingesting under a new model replaces each document whole,
-- which drops the old model's vectors for it, and 'prune' with the old name
-- drops whatever is left. Each model gets its own HNSW index, partial on
-- that model, built by 'ensureIndex' once its dimension is known.
--
-- The vector extension is created by the NixOS module as the database
-- superuser, because pgvector is not a trusted extension; 'migrate' checks
-- for it and says so when it is missing.
module OpenSlop.Rag.Store
  ( Connection
  , connectStore
  , migrate
  , Document (..)
  , DocState (..)
  , docState
  , replaceDocument
  , removeMissing
  , ensureIndex
  , Hit (..)
  , search
  , prune
  , Stats (..)
  , stats
  ) where

import Control.Monad (forM_, void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as B16
import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple
  ( Connection
  , Only (..)
  , connectPostgreSQL
  , execute
  , execute_
  , executeMany
  , query
  , query_
  , withTransaction
  )
import OpenSlop.Rag.Embed (vectorLiteral)
import OpenSlop.Rag.Split (Piece (..))

-- | Connect, with NOTICEs off: every IF NOT EXISTS in 'migrate' would
-- otherwise print one on each run.
connectStore :: Text -> IO Connection
connectStore conninfo = do
  conn <- connectPostgreSQL (TE.encodeUtf8 conninfo)
  void $ execute_ conn "SET client_min_messages = warning"
  pure conn

schema :: [String]
schema =
  [ "CREATE TABLE IF NOT EXISTS rag_documents\
    \ ( id bigserial PRIMARY KEY\
    \ , root text NOT NULL\
    \ , path text NOT NULL UNIQUE\
    \ , sha256 text NOT NULL\
    \ , kind text NOT NULL\
    \ , bytes bigint NOT NULL\
    \ , ingested_at timestamptz NOT NULL DEFAULT now()\
    \ )"
  , "CREATE INDEX IF NOT EXISTS rag_documents_root ON rag_documents (root)"
  , "CREATE TABLE IF NOT EXISTS rag_chunks\
    \ ( id bigserial PRIMARY KEY\
    \ , document_id bigint NOT NULL REFERENCES rag_documents (id) ON DELETE CASCADE\
    \ , ordinal int NOT NULL\
    \ , heading text NOT NULL\
    \ , body text NOT NULL\
    \ , line_from int NOT NULL\
    \ , line_to int NOT NULL\
    \ , tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', heading || ' ' || body)) STORED\
    \ , UNIQUE (document_id, ordinal)\
    \ )"
  , "CREATE INDEX IF NOT EXISTS rag_chunks_tsv ON rag_chunks USING gin (tsv)"
  , "CREATE TABLE IF NOT EXISTS rag_embeddings\
    \ ( chunk_id bigint NOT NULL REFERENCES rag_chunks (id) ON DELETE CASCADE\
    \ , model text NOT NULL\
    \ , dims int NOT NULL\
    \ , embedding vector NOT NULL\
    \ , PRIMARY KEY (chunk_id, model)\
    \ )"
  , "CREATE INDEX IF NOT EXISTS rag_embeddings_model ON rag_embeddings (model)"
  ]

migrate :: Connection -> IO (Either Text ())
migrate conn = do
  ext <- query_ conn "SELECT count(*) FROM pg_extension WHERE extname = 'vector'" :: IO [Only Int64]
  case ext of
    [Only n] | n > 0 -> do
      withTransaction conn (forM_ schema (void . execute_ conn . fromString))
      pure (Right ())
    _ ->
      pure . Left $
        "the vector extension is not installed in this database; \
        \services.open-slop.rag creates it, or run CREATE EXTENSION vector as the postgres superuser"

data Document = Document
  { root :: Text
  , path :: Text
  , sha256 :: Text
  , kind :: Text
  , bytes :: Int64
  }

-- | Whether a file needs work for a given embedding model.
data DocState
  = Fresh
  -- ^ same content, every chunk embedded by this model
  | NeedsEmbeddings
  -- ^ same content, some chunk lacks this model's vector
  | Changed
  -- ^ new, or different content
  deriving stock (Eq, Show)

docState :: Connection -> Text -> Text -> Text -> IO DocState
docState conn model path sha = do
  rows <-
    query
      conn
      "SELECT d.sha256,\
      \ (SELECT count(*) FROM rag_chunks c WHERE c.document_id = d.id),\
      \ (SELECT count(*) FROM rag_chunks c JOIN rag_embeddings e ON e.chunk_id = c.id\
      \   WHERE c.document_id = d.id AND e.model = ?)\
      \ FROM rag_documents d WHERE d.path = ?"
      (model, path)
  pure case rows of
    [(old, chunks, embedded)]
      | old /= sha -> Changed
      | (chunks :: Int64) == (embedded :: Int64) -> Fresh
      | otherwise -> NeedsEmbeddings
    _ -> Changed

-- | Write a document, its chunks and their vectors in one transaction,
-- replacing whatever the path held before. The vectors are in piece order.
replaceDocument :: Connection -> Text -> Document -> [Piece] -> [[Double]] -> IO ()
replaceDocument conn model d pieces vectors = withTransaction conn do
  void $ execute conn "DELETE FROM rag_documents WHERE path = ?" (Only d.path)
  [Only docId] <-
    query
      conn
      "INSERT INTO rag_documents (root, path, sha256, kind, bytes) VALUES (?,?,?,?,?) RETURNING id"
      (d.root, d.path, d.sha256, d.kind, d.bytes)
  forM_ (zip pieces vectors) \(p, v) -> do
    [Only chunkId] <-
      query
        conn
        "INSERT INTO rag_chunks (document_id, ordinal, heading, body, line_from, line_to)\
        \ VALUES (?,?,?,?,?,?) RETURNING id"
        (docId :: Int64, p.ordinal, T.intercalate " > " p.heading, p.body, p.lineFrom, p.lineTo)
    void $
      execute
        conn
        "INSERT INTO rag_embeddings (chunk_id, model, dims, embedding) VALUES (?,?,?,?::vector)"
        (chunkId :: Int64, model, length v, vectorLiteral v)

-- | Delete the documents under a root whose paths were not seen in this
-- pass: the file was deleted or moved. Returns how many went.
removeMissing :: Connection -> Text -> [Text] -> IO Int64
removeMissing conn root seen = withTransaction conn do
  void $ execute_ conn "CREATE TEMP TABLE IF NOT EXISTS rag_seen (path text PRIMARY KEY) ON COMMIT DROP"
  void $ executeMany conn "INSERT INTO rag_seen (path) VALUES (?) ON CONFLICT DO NOTHING" (map Only seen)
  execute
    conn
    "DELETE FROM rag_documents d WHERE d.root = ? AND NOT EXISTS (SELECT 1 FROM rag_seen s WHERE s.path = d.path)"
    (Only root)

-- | The partial HNSW index for one model. DDL takes no parameters, so the
-- model name goes in as a quoted literal and the index name is a digest of
-- it.
ensureIndex :: Connection -> Text -> Int -> IO ()
ensureIndex conn model dims = do
  let name = "rag_hnsw_" <> T.take 16 (TE.decodeUtf8 (B16.encode (SHA256.hash (TE.encodeUtf8 model)))) <> "_" <> T.pack (show dims)
      sql =
        "CREATE INDEX IF NOT EXISTS "
          <> name
          <> " ON rag_embeddings USING hnsw ((embedding::vector("
          <> T.pack (show dims)
          <> ")) vector_cosine_ops) WHERE model = "
          <> quoteLiteral model
          <> " AND dims = "
          <> T.pack (show dims)
  void $ execute_ conn (fromString (T.unpack sql))

quoteLiteral :: Text -> Text
quoteLiteral t = "'" <> T.replace "'" "''" t <> "'"

data Hit = Hit
  { path :: Text
  , heading :: Text
  , body :: Text
  , lineFrom :: Int
  , lineTo :: Int
  , score :: Double
  , viaVector :: Bool
  , viaWords :: Bool
  }
  deriving stock (Show)

-- | Hybrid search: the @depth@ nearest chunks by cosine distance and the
-- @depth@ best full-text matches, fused by reciprocal rank (k = 60), best
-- @limit@ returned. A chunk found both ways ranks above one found either
-- way at the same position.
--
-- The word half matches ANY of the question's stemmed words, ranked by
-- cover density, not all of them: a question is phrased in words the
-- answer does not use ("what port does it use"), and requiring every word
-- would leave this half empty for most questions.
search :: Connection -> Text -> [Double] -> Text -> Int -> Int -> IO [Hit]
search conn model qvec qtext depth limit = do
  let dims = length qvec
      d = T.pack (show dims)
      dist = "e.embedding::vector(" <> d <> ") <=> ?::vector(" <> d <> ")"
      sql =
        "WITH v AS (\
        \  SELECT c.id, row_number() OVER (ORDER BY "
          <> dist
          <> ") AS r FROM rag_embeddings e JOIN rag_chunks c ON c.id = e.chunk_id\
             \  WHERE e.model = ? AND e.dims = "
          <> d
          <> " ORDER BY "
          <> dist
          <> " LIMIT ?),\
             \ k AS (\
             \  SELECT c.id, row_number() OVER (ORDER BY ts_rank_cd(c.tsv, w.q) DESC) AS r\
             \  FROM rag_chunks c,\
             \   (SELECT replace(plainto_tsquery('english', ?)::text, '&', '|')::tsquery AS q) w\
             \  WHERE c.tsv @@ w.q ORDER BY ts_rank_cd(c.tsv, w.q) DESC LIMIT ?),\
             \ f AS (\
             \  SELECT id, sum(1.0 / (60 + r))::float8 AS score,\
             \   bool_or(src = 'v') AS via_v, bool_or(src = 'k') AS via_k\
             \  FROM (SELECT id, r, 'v' AS src FROM v UNION ALL SELECT id, r, 'k' FROM k) u GROUP BY id)\
             \ SELECT d.path, c.heading, c.body, c.line_from, c.line_to, f.score, f.via_v, f.via_k\
             \ FROM f JOIN rag_chunks c ON c.id = f.id JOIN rag_documents d ON d.id = c.document_id\
             \ ORDER BY f.score DESC, d.path, c.ordinal LIMIT ?"
      lit = vectorLiteral qvec
  rows <- query conn (fromString (T.unpack sql)) (lit, model, lit, depth, qtext, depth, limit)
  pure [Hit p h b lf lt s vv vk | (p, h, b, lf, lt, s, vv, vk) <- rows]

-- | Remove one model's vectors, or every document under a root.
prune :: Connection -> Either Text Text -> IO Int64
prune conn = \case
  Left model -> execute conn "DELETE FROM rag_embeddings WHERE model = ?" (Only model)
  Right root -> execute conn "DELETE FROM rag_documents WHERE root = ?" (Only root)

data Stats = Stats
  { documents :: Int64
  , chunks :: Int64
  , byModel :: [(Text, Int, Int64)]
  , roots :: [(Text, Int64)]
  }

stats :: Connection -> IO Stats
stats conn = do
  [Only documents] <- query_ conn "SELECT count(*) FROM rag_documents"
  [Only chunks] <- query_ conn "SELECT count(*) FROM rag_chunks"
  byModel <- query_ conn "SELECT model, dims, count(*) FROM rag_embeddings GROUP BY model, dims ORDER BY model"
  roots <- query_ conn "SELECT root, count(*) FROM rag_documents GROUP BY root ORDER BY root"
  pure Stats {documents, chunks, byModel, roots}
