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
  , DocInfo (..)
  , listDocuments
  , forgetDocument
  , chunksMatching
  , SessionInfo (..)
  , openSession
  , listSessions
  , sessionTurns
  , sessionTurnsStored
  , findSession
  , addTurn
  ) where

import Control.Monad (forM_, void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as B16
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.Types (PGArray (..))
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
  , (:.) (..)
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
  , "CREATE TABLE IF NOT EXISTS rag_sessions\
    \ ( id bigserial PRIMARY KEY\
    \ , name text NOT NULL UNIQUE\
    \ , created timestamptz NOT NULL DEFAULT now()\
    \ )"
  , "CREATE TABLE IF NOT EXISTS rag_turns\
    \ ( id bigserial PRIMARY KEY\
    \ , session_id bigint NOT NULL REFERENCES rag_sessions (id) ON DELETE CASCADE\
    \ , role text NOT NULL CHECK (role IN ('user', 'assistant'))\
    \ , content text NOT NULL\
    \ , sources jsonb\
    \ , model text\
    \ , created timestamptz NOT NULL DEFAULT now()\
    \ )"
  , "CREATE INDEX IF NOT EXISTS rag_turns_session ON rag_turns (session_id, id)"
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

-- | How many chunks have a path containing the first text and a heading
-- or body containing the second, ignoring case. For checking that an
-- evaluation's expected answer is in the index at all, so that a case
-- whose phrase falls across two chunks, or names a file that was not
-- ingested, is reported as a wrong case and not as a missed retrieval.
chunksMatching :: Connection -> Text -> Text -> IO Int
chunksMatching conn pathPart phrase = do
  rows <-
    query
      conn
      "SELECT count(*) FROM rag_chunks c JOIN rag_documents d ON d.id = c.document_id \
      \WHERE strpos(lower(d.path), lower(?)) > 0 \
      \AND strpos(lower(c.heading || E'\\n' || c.body), lower(?)) > 0"
      (pathPart, phrase) ::
      IO [Only Int64]
  pure case rows of
    [Only n] -> fromIntegral n
    _ -> 0

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
  , similarity :: Double
  -- ^ cosine similarity of this chunk's vector to the question's, from -1
  -- to 1, whichever half found it. Unlike 'score', which only says how a
  -- chunk ranked among the candidates, this says how close it is, so it
  -- can tell a weak candidate from a strong one.
  }
  deriving stock (Show)

-- | Hybrid search: the @depth@ nearest chunks by cosine distance and the
-- @depth@ best full-text matches, fused by reciprocal rank (k = 60), best
-- @limit@ returned. A chunk found both ways ranks above one found either
-- way at the same position.
--
-- The word half matches ANY of the question's stemmed words, not all of
-- them: a question is phrased in words the answer does not use ("what port
-- does it use"), and requiring every word would leave this half empty for
-- most questions. A chunk scores the sum, over the distinct question words
-- it contains, of ln(1 + N / (1 + n)), where N is the number of chunks in
-- the index and n the number containing that word, so a rare word counts
-- for much more than a common one and a chunk with several of the rare
-- words ranks first. How often a word repeats within the chunk does not
-- count.
--
-- Until 2026-10-18 this half ranked by ts_rank_cd over the same words,
-- which knows nothing of rarity. In cheeblr, "What error does the backend
-- return when a request tries to modify a refund transaction?" ranked
-- chunks dense with "transaction" and "error", which thousands of chunks
-- have, above the one chunk with "modify", "refund" and "transaction"
-- together, and the search never returned it.
--
-- The counts are taken over the whole index, not the scope, so a word's
-- weight does not change with --under. Each is one lookup in the GIN
-- index on tsv, one per distinct word of the question.
--
-- A non-empty scope keeps only documents whose path starts with one of the
-- given prefixes, in both halves, so the candidates are drawn from the
-- scope rather than filtered out of the whole index afterwards.
--
-- Every hit also carries its cosine similarity to the question, computed
-- for word matches too, so "OpenSlop.Rag.Retrieve" can drop candidates
-- that are far from the question however they ranked.
search :: Connection -> Text -> [Double] -> Text -> [Text] -> Int -> Int -> IO [Hit]
search conn model qvec qtext scope depth limit = do
  let dims = length qvec
      d = T.pack (show dims)
      dist = "e.embedding::vector(" <> d <> ") <=> ?::vector(" <> d <> ")"
      sql =
        "WITH v AS (\
        \  SELECT c.id, row_number() OVER (ORDER BY "
          <> dist
          <> ") AS r FROM rag_embeddings e JOIN rag_chunks c ON c.id = e.chunk_id\
             \  JOIN rag_documents sd ON sd.id = c.document_id\
             \  WHERE e.model = ? AND e.dims = "
          <> d
          <> scoped "sd"
          <> " ORDER BY "
          <> dist
          <> " LIMIT ?),\
             \ terms AS (\
             \  SELECT DISTINCT ('''' || replace(t, '''', '''''') || '''')::tsquery AS q\
             \  FROM unnest(tsvector_to_array(to_tsvector('english', ?))) t),\
             \ rarity AS (\
             \  SELECT q, ln(1 + (SELECT count(*) FROM rag_chunks)::float8\
             \   / (1 + (SELECT count(*) FROM rag_chunks n WHERE n.tsv @@ terms.q))) AS w FROM terms),\
             \ k AS (\
             \  SELECT c.id, row_number() OVER (ORDER BY sum(i.w) DESC, c.id) AS r\
             \  FROM rarity i JOIN rag_chunks c ON c.tsv @@ i.q\
             \  JOIN rag_documents kd ON kd.id = c.document_id\
             \  WHERE true"
          <> scoped "kd"
          <> " GROUP BY c.id ORDER BY sum(i.w) DESC, c.id LIMIT ?),\
             \ f AS (\
             \  SELECT id, sum(1.0 / (60 + r))::float8 AS score,\
             \   bool_or(src = 'v') AS via_v, bool_or(src = 'k') AS via_k\
             \  FROM (SELECT id, r, 'v' AS src FROM v UNION ALL SELECT id, r, 'k' FROM k) u GROUP BY id)\
             \ SELECT d.path, c.heading, c.body, c.line_from, c.line_to, f.score, f.via_v, f.via_k,\
             \  (1 - (s.embedding::vector("
          <> d
          <> ") <=> ?::vector("
          <> d
          <> ")))::float8\
             \ FROM f JOIN rag_chunks c ON c.id = f.id JOIN rag_documents d ON d.id = c.document_id\
             \ JOIN rag_embeddings s ON s.chunk_id = c.id AND s.model = ? AND s.dims = "
          <> d
          <> "\
             \ ORDER BY f.score DESC, d.path, c.ordinal LIMIT ?"
      lit = vectorLiteral qvec
      patterns = PGArray (map likePrefix scope)
      scoped alias
        | null scope = ""
        | otherwise = " AND " <> alias <> ".path LIKE ANY (?)"
  rows <-
    if null scope
      then query conn (fromString (T.unpack sql)) ((lit, model, lit, depth, qtext, depth) :. (lit, model, limit))
      else query conn (fromString (T.unpack sql)) ((lit, model, patterns, lit, depth, qtext) :. (patterns, depth, lit, model, limit))
  pure [Hit p h b lf lt s vv vk sim | (p, h, b, lf, lt, s, vv, vk, sim) <- rows]

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

-- | A path prefix as a LIKE pattern, with LIKE's own wildcards escaped.
likePrefix :: Text -> Text
likePrefix p = T.concatMap esc p <> "%"
  where
    esc c
      | c `elem` ['%', '_', '\\'] = T.pack ['\\', c]
      | otherwise = T.singleton c

data DocInfo = DocInfo
  { path :: Text
  , kind :: Text
  , bytes :: Int64
  , chunks :: Int64
  , ingestedAt :: UTCTime
  }

-- | The indexed documents, optionally only those under the given prefixes,
-- in path order.
listDocuments :: Connection -> [Text] -> IO [DocInfo]
listDocuments conn scope = do
  rows <-
    if null scope
      then query_ conn (fromString (docSql ""))
      else query conn (fromString (docSql " WHERE d.path LIKE ANY (?)")) (Only (PGArray (map likePrefix scope)))
  pure [DocInfo p k b n t | (p, k, b, n, t) <- rows]
  where
    docSql w =
      "SELECT d.path, d.kind, d.bytes, (SELECT count(*) FROM rag_chunks c WHERE c.document_id = d.id), d.ingested_at\
      \ FROM rag_documents d"
        <> w
        <> " ORDER BY d.path"

-- | Remove one document, its chunks and its vectors. Returns whether it
-- was there.
forgetDocument :: Connection -> Text -> IO Bool
forgetDocument conn p = (> 0) <$> execute conn "DELETE FROM rag_documents WHERE path = ?" (Only p)

data SessionInfo = SessionInfo
  { sessionId :: Int64
  , name :: Text
  , created :: UTCTime
  , turns :: Int64
  }

-- | The session with this name, created if it does not exist.
openSession :: Connection -> Text -> IO Int64
openSession conn n = do
  [Only i] <-
    query
      conn
      "INSERT INTO rag_sessions (name) VALUES (?) ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id"
      (Only n)
  pure i

listSessions :: Connection -> IO [SessionInfo]
listSessions conn = do
  rows <-
    query_
      conn
      "SELECT s.id, s.name, s.created, (SELECT count(*) FROM rag_turns t WHERE t.session_id = s.id)\
      \ FROM rag_sessions s ORDER BY s.created"
  pure [SessionInfo i n c t | (i, n, c, t) <- rows]

-- | The session's turns in order, as (role, content).
sessionTurns :: Connection -> Int64 -> IO [(Text, Text)]
sessionTurns conn sid = query conn "SELECT role, content FROM rag_turns WHERE session_id = ? ORDER BY id" (Only sid)

-- | The session with this name, without creating it.
findSession :: Connection -> Text -> IO (Maybe Int64)
findSession conn n = do
  rows <- query conn "SELECT id FROM rag_sessions WHERE name = ?" (Only n)
  pure case rows of
    [Only i] -> Just i
    _ -> Nothing

-- | The session's turns in order with what was stored beside each:
-- (role, content, sources). llmq-index chat stores an assistant turn's
-- sources as a list of locations; the gateway's ask jobs store the whole
-- cited answer, { parts, sources }, so the web page can show it again.
sessionTurnsStored :: Connection -> Int64 -> IO [(Text, Text, Maybe Value)]
sessionTurnsStored conn sid = query conn "SELECT role, content, sources FROM rag_turns WHERE session_id = ? ORDER BY id" (Only sid)

addTurn :: Connection -> Int64 -> Text -> Text -> Maybe Value -> Maybe Text -> IO ()
addTurn conn sid role content sources model =
  void $
    execute
      conn
      "INSERT INTO rag_turns (session_id, role, content, sources, model) VALUES (?,?,?,?,?)"
      (sid, role, content, sources, model)