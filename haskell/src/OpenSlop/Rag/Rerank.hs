-- | Reordering retrieved chunks by a cross-encoder, through a LAN
-- llama-server started with --reranking.
--
-- The embedding search scores a chunk by how close its vector is to the
-- question's, and each vector was made without seeing the other text. On a
-- repository where every chunk is about the same machines, that puts them
-- all within a few hundredths of each other: measured 2026-10-16 on
-- neoblade-config with nomic-embed-text, the chunk that answered "which
-- machine holds the binary cache, and on what port?" scored 0.660 and an
-- unrelated chunk about a cached homebeacon verdict scored 0.637. A
-- reranker reads the question and the chunk together and scores whether
-- the chunk answers the question, which is the distinction the embedding
-- cannot make.
--
-- It is slow in proportion to the text it reads, so only the best few
-- candidates of the hybrid search are sent (llmq-index's --rerank-depth),
-- and each is cut to 'documentChars' first.
--
-- The request is llama.cpp's /v1/rerank: a query, a list of documents,
-- and a reply of (index, relevance_score) pairs. Only llama-server serves
-- it; any other engine is refused when the reranker is configured.
module OpenSlop.Rag.Rerank
  ( Reranker (..)
  , reranker
  , rerank
  , withinMargin
  , documentChars
  ) where

import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.List (sort, sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue (Engine (..), engineName)
import OpenSlop.Http (Auth (..), Client, describeFailure, postJsonWithin)
import OpenSlop.Rag.Locality (Lan, lanUrl)
import OpenSlop.Rag.Store (Hit (..))

data Reranker = Reranker
  { server :: Lan
  , model :: Text
  }

-- | Refuses an engine that has no rerank route.
reranker :: Lan -> Engine -> Text -> Either Text Reranker
reranker server engine model = case engine of
  LlamaServer -> Right Reranker {server, model}
  other -> Left (engineName other <> " has no rerank route; the reranker must be a llama-server started with --reranking")

-- | The most characters of one chunk sent to the reranker. A chunk is
-- packed to 1,600 characters and never exceeds 2,400 (see
-- "OpenSlop.Rag.Split"), so this cuts nothing an ingest produced; it keeps
-- an oversized chunk from overflowing the server's batch, which for a
-- non-causal model must hold the question and the whole document at once.
documentChars :: Int
documentChars = 2400

-- | The reranked hits scoring no more than the margin below the best, in
-- order. bge-reranker's scores are logits, not probabilities: on
-- 2026-10-16 the two chunks that answered a question about the binary cache
-- scored -0.87 and -1.53, and the next, unrelated, -3.82. The four sent
-- with them by --sources 6 alone could only mislead the model, and one did:
-- it named oracle, whose chunk was sixth, as the machine. A margin is used
-- rather than a fixed floor because the scale of the best score moves with
-- the question; the gap between an answer and a non-answer is what stays.
withinMargin :: Double -> [(a, Double)] -> [(a, Double)]
withinMargin _ [] = []
withinMargin margin scored@((_, best) : _) = takeWhile (\(_, s) -> s >= best - margin) scored

data Scored = Scored Int Double

instance FromJSON Scored where
  parseJSON = withObject "rerank result" \o -> Scored <$> o .: "index" <*> o .: "relevance_score"

newtype Results = Results [Scored]

instance FromJSON Results where
  parseJSON = withObject "rerank reply" \o -> Results <$> o .: "results"

-- | The hits with their relevance scores, best first. Every hit sent comes
-- back; a reply that leaves one out or names an index that was not sent is
-- an error rather than a shorter list.
rerank :: Client -> Reranker -> Text -> [Hit] -> IO (Either Text [(Hit, Double)])
rerank _ _ _ [] = pure (Right [])
rerank client r question hits = do
  let documents = [T.take documentChars (if T.null h.heading then h.body else h.heading <> "\n" <> h.body) | h <- hits]
      body =
        object
          [ "model" .= r.model
          , "query" .= question
          , "documents" .= documents
          , "top_n" .= length hits
          ]
  reply <- postJsonWithin (Just 1800) client NoAuth (lanUrl r.server) "/v1/rerank" body
  pure case reply of
    Left f -> Left (engineName LlamaServer <> " rerank: " <> describeFailure f)
    Right raw -> case Aeson.eitherDecode raw of
      Left err -> Left ("unreadable rerank reply: " <> T.pack err)
      Right (Results scored)
        | length scored /= length hits ->
            Left ("sent " <> tshow (length hits) <> " documents to rerank, got " <> tshow (length scored) <> " scores")
        | sort [i | Scored i _ <- scored] /= [0 .. length hits - 1] ->
            Left "the rerank reply does not score each document sent exactly once"
        | otherwise ->
            Right (sortOn (Down . snd) [(hits !! i, s) | Scored i s <- scored])
  where
    tshow = T.pack . show