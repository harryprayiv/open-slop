-- | Choosing the sources for a question and answering it from them: the
-- part of llmq-index that does not depend on a terminal.
--
-- llmq-index's ask, chat and eval use it, and so does open-slop-gateway,
-- which serves the index as a model (see "OpenSlop.Gateway.Server"), so a
-- question from a Grace program, a script or a browser is answered by the
-- same search, reranking, margin and packing as one asked at the terminal,
-- and the measurements in llmq-index's evaluation sets hold for all of
-- them. 'Asking' carries everything a question needs; 'askingFrom' builds
-- one from a catalogue and the same settings llmq-index takes.
--
-- What it reports as it works (the rewritten question, the reranker's
-- scores, how many sources were kept) goes to 'note', so llmq-index can
-- print it on the terminal and the gateway can put it in its log.
module OpenSlop.Rag.Ask
  ( Asking (..)
  , Selection (..)
  , select
  , answerWith
  , AskConfig (..)
  , defaultAskConfig
  , askingFrom
  , guideKinds
  ) where

import Control.Exception (AsyncException (..), SomeException, displayException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric (showFFloat)
import OpenSlop.Capacity (Capacity (..), capacityFor, learn, measuredEntry, probeWindow)
import OpenSlop.Catalogue (Backend (..), Catalogue (..), Endpoint (..), endpointId, lookupModel)
import OpenSlop.Http (Client)
import OpenSlop.Measured (measuredPath, readMeasured)
import OpenSlop.Rag.Embed (Embedder, embedder)
import OpenSlop.Rag.Locality (Lan, onLan)
import OpenSlop.Rag.Rerank (Reranker, rerank, reranker)
import OpenSlop.Rag.Retrieve
import OpenSlop.Rag.Store (Connection, Hit (..))

data Asking = Asking
  { client :: Client
  , conn :: Connection
  , embedWith :: Embedder
  , chatTo :: Chat
  , capacity :: IORef Capacity
  , depth :: Int
  , sources :: Int
  -- ^ the most sources one answer is given
  , rerankWith :: Maybe Reranker
  -- ^ when set, the best 'rerankDepth' candidates are reordered by it;
  -- without one, candidates are cut by similarity, 'relevanceMargin' below
  -- their part's best
  , rerankDepth :: Int
  , rerankMargin :: Double
  -- ^ reranked candidates scoring more than this below their part's best
  -- are dropped
  , splitQuestions :: Bool
  -- ^ split a question that may ask several things and search each part
  , guides :: [(Text, Int)]
  -- ^ document kinds searched on their own for every question, and how
  -- many of each are sent first, before the other sources; see 'select'
  , maxWait :: Maybe Double
  , scope :: IORef [Text]
  , note :: Text -> IO ()
  -- ^ where progress goes: llmq-index's stderr, the gateway's log
  }


-- | The sources chosen for one question, and how they were chosen.
data Selection = Selection
  { query :: Text
  -- ^ the question as searched, after rewriting against the history
  , searched :: [Text]
  -- ^ the parts searched separately; the query alone when it was not split
  , found :: [[Hit]]
  -- ^ each part's hits from the hybrid search, in its fused order, before
  -- the reranker's depth cuts them
  , ranked :: [(Hit, Double)]
  -- ^ every part's candidates, best first, each scored relative to the
  -- best candidate of its own part (so each part's best is 0): the
  -- reranker's score with a reranker, else similarity
  , guides :: [Hit]
  -- ^ the best of each kind in 'Asking'.guides, searched on their own
  , kept :: [Hit]
  -- ^ those within the margin, at most --sources
  , packed :: [Hit]
  -- ^ 'guides', then those of 'kept' not among them, as many as fit the
  -- model's capacity; what the model is given
  }

-- | Rewrite against the history, split into parts, retrieve and score
-- each part, merge, choose and pack. Returns the sources the model would
-- be given, or why there are none.
--
-- Each part's scores are taken relative to that part's best candidate
-- before the parts are merged, so the margin is applied within each part:
-- a part whose best answer the reranker scores low is not cut because
-- another part's answer scores high. The reranker's depth is shared
-- between the parts, at least 8 each, so a two-part question costs about
-- what one part did.
--
-- Splitting is off unless asked for (llmq-index's --split). Measured on
-- 2026-10-17 over the three evaluation sets, it kept the same 20 of 25
-- answering chunks as searching whole, cost a model call per compound
-- question, and sent more sources, because each part that the files cannot
-- answer still contributes its own best candidates.
--
-- Specifications and chase bundles are also searched on their own, for
-- the question as searched, and the best few of each ('Asking'.guides) are
-- sent first. A question about how a program fits together ("the control
-- flow of the frontend") is answered by an .allium rule or a chase module
-- summary rather than by any one piece of code, but in the shared search
-- such a chunk competes with every file of the repository and lost to a
-- spago.yaml and a test client for that question on 2026-10-24. A search
-- of its own puts the closest of them in front of the model whatever the
-- code ranks. Each costs one more search and, with a reranker, one more
-- reranking of a few candidates; a kind with nothing in scope adds
-- nothing, and a failure there is noted and the question goes on without
-- it.
--
-- Searching beside the question for the chat model's guess at the
-- answer's text was tried the same day and removed. The model has never
-- seen these repositories, so its guesses were generic code (a
-- `reciprocalRankFusion = 0.5`, JavaScript for a PureScript frontend),
-- each took 7 to 66 seconds on oracle, neither of the two chunks the
-- search misses was found, and interleaving the guess's hits pushed two
-- answers that ranked within --rerank-depth out past it.
select :: Asking -> [(Text, Text)] -> Text -> IO (Either Text Selection)
select a history question = do
  cap <- readIORef a.capacity
  standalone <- condense a.client a.chatTo cap history question
  case standalone of
    Left e -> pure (Left e)
    Right q -> do
      when (q /= question) (a.note ("searching for: " <> q))
      parts <-
        if a.splitQuestions && mayHaveParts q
          then
            splitParts a.client a.chatTo cap q >>= \case
              Left e -> a.note ("not split (" <> e <> "); searching the question whole") >> pure [q]
              Right ps -> pure ps
          else pure [q]
      when (length parts > 1) (a.note ("searching " <> T.pack (show (length parts)) <> " parts: " <> T.intercalate " | " parts))
      sc <- readIORef a.scope
      let depthEach = if length parts > 1 then max 8 (a.rerankDepth `div` length parts) else a.rerankDepth
      scored <- traverse (scorePart a sc depthEach) parts
      case sequence scored of
        Left e -> pure (Left e)
        Right results
          | all (null . snd) results -> pure (Left (if null sc then "nothing in the index matches that question" else "nothing under " <> T.intercalate ", " sc <> " matches that question"))
          | otherwise -> do
              guides <- concat <$> traverse (uncurry (guideKind a sc q)) [(k, n) | (k, n) <- a.guides, n > 0]
              let found = map fst results
                  ranked = mergeParts (map snd results)
                  margin = maybe relevanceMargin (const a.rerankMargin) a.rerankWith
                  close = [h | (h, s) <- ranked, s >= negate margin]
                  kept = take a.sources close
                  guideKeys = map key guides
                  sent = guides <> [h | h <- kept, key h `notElem` guideKeys]
                  packed = packSources cap a.maxWait (historyChars cap a.maxWait history question) sent
              a.note
                ( T.pack (show (length close))
                    <> " within "
                    <> T.pack (showFFloat (Just 2) margin "")
                    <> " of their part's best ("
                    <> (if isJust a.rerankWith then "--rerank-margin" else "similarity")
                    <> "), kept "
                    <> T.pack (show (length kept))
                    <> " (--sources "
                    <> T.pack (show a.sources)
                    <> "), "
                    <> T.pack (show (length guides))
                    <> " specification and summary sources put first, "
                    <> T.pack (show (length packed))
                    <> " of all of them fit"
                )
              pure (Right Selection {query = q, searched = parts, found, ranked, guides, kept, packed})

-- | One part's hits from the search, and its candidates best first, scored
-- relative to the best.
scorePart :: Asking -> [Text] -> Int -> Text -> IO (Either Text ([Hit], [(Hit, Double)]))
scorePart a sc depthEach part =
  retrieve a.client a.conn a.embedWith Retrieval {depth = a.depth, limit = 2 * a.depth, scope = sc} part >>= \case
    Left e -> pure (Left e)
    Right [] -> pure (Right ([], []))
    Right hits -> case a.rerankWith of
      Nothing -> pure (Right (hits, relative (sortOn (Down . snd) [(h, h.similarity) | h <- hits])))
      Just rr -> do
        let candidates = take depthEach hits
        t0 <- getCurrentTime
        r <- rerank a.client rr part candidates
        t1 <- getCurrentTime
        case r of
          Left e -> pure (Left e)
          Right scored -> do
            a.note
              ( "reranked the best "
                  <> T.pack (show (length candidates))
                  <> " of "
                  <> T.pack (show (length hits))
                  <> " for \""
                  <> T.take 60 part
                  <> "\" in "
                  <> T.pack (showFFloat (Just 1) (realToFrac (diffUTCTime t1 t0) :: Double) "")
                  <> " s, scores "
                  <> T.intercalate " " [T.pack (showFFloat (Just 2) s "") | (_, s) <- take 6 scored]
              )
            pure (Right (hits, relative scored))
  where
    relative = \case
      [] -> []
      xs@((_, best) : _) -> [(h, s - best) | (h, s) <- xs]

-- | The best @n@ chunks of one kind for the question: the hybrid search
-- within that kind, reordered by the reranker when there is one. Nothing
-- of that kind in scope, or a failure, gives none.
guideKind :: Asking -> [Text] -> Text -> Text -> Int -> IO [Hit]
guideKind a sc q kind n =
  retrieveKinds a.client a.conn a.embedWith [kind] Retrieval {depth = a.depth, limit = a.depth, scope = sc} q >>= \case
    Left e -> a.note ("no " <> kind <> " sources: " <> e) >> pure []
    Right [] -> pure []
    Right hits -> case a.rerankWith of
      Nothing -> pure (take n (sortOn (Down . (.similarity)) hits))
      Just rr ->
        rerank a.client rr q (take (2 * n + 4) hits) >>= \case
          Left e -> a.note ("the " <> kind <> " sources were not reranked (" <> e <> ")") >> pure (take n hits)
          Right scored -> do
            let chosen = take n scored
            a.note ("best " <> kind <> " sources: " <> T.intercalate ", " [h.path <> ":" <> T.pack (show h.lineFrom) <> (if T.null h.heading then "" else " (" <> h.heading <> ")") | (h, _) <- chosen])
            pure (map fst chosen)

-- | Where a chunk is, which identifies it.
key :: Hit -> (Text, Int, Int)
key h = (h.path, h.lineFrom, h.lineTo)

-- | The parts' candidates as one list, best first, a chunk found by more
-- than one part kept once with its best score.
mergeParts :: [[(Hit, Double)]] -> [(Hit, Double)]
mergeParts perPart = sortOn (Down . snd) (Map.elems (Map.fromListWith better [(key h, (h, s)) | (h, s) <- concat perPart]))
  where
    better x y = if snd x >= snd y then x else y

-- | Ask the model, constrained to the answer schema, with the sources
-- given, and learn from the token count the server reports. The raw reply
-- goes to the callback as it streams.
answerWith :: Asking -> [(Text, Text)] -> Text -> [Hit] -> (Text -> IO ()) -> IO (Either Text Answer)
answerWith a history question packed onText = do
  cap <- readIORef a.capacity
  r <- try (answerStream a.client a.chatTo cap a.maxWait history question packed onText)
  case r of
    Left UserInterrupt -> pure (Left "stopped")
    Left e -> throwIO e
    Right (Left e) -> pure (Left e)
    Right (Right ans) -> do
      forM_ ans.promptTokens \n -> modifyIORef' a.capacity (\c -> learn c ans.promptChars n)
      pure (Right ans)


-- | What a question needs besides the database: the servers, named as
-- endpoints in the catalogue (row/backend), the models, and the search
-- settings. The defaults are llmq-index's, which its evaluation sets chose;
-- see its Main for the measurements behind each.
data AskConfig = AskConfig
  { embedAt :: Text
  , embedModel :: Text
  , chatAt :: Text
  , chatModel :: Text
  , rerankAt :: Maybe Text
  , rerankModel :: Maybe Text
  , depth :: Int
  , sources :: Int
  , rerankDepth :: Int
  , rerankMargin :: Double
  , splitQuestions :: Bool
  , specSources :: Int
  -- ^ .allium chunks sent first with every answer
  , chaseSources :: Int
  -- ^ chase bundle chunks sent first with every answer
  , maxWait :: Maybe Double
  }

defaultAskConfig :: Text -> Text -> Text -> Text -> AskConfig
defaultAskConfig embedAt embedModel chatAt chatModel =
  AskConfig
    { embedAt
    , embedModel
    , chatAt
    , chatModel
    , rerankAt = Nothing
    , rerankModel = Nothing
    , depth = 40
    , sources = 4
    , rerankDepth = 30
    , rerankMargin = 2.0
    , splitQuestions = False
    , specSources = 2
    , chaseSources = 2
    , maxWait = Nothing
    }

-- | The kinds searched on their own for every question, by Extract's names
-- for them, with how many of each are sent.
guideKinds :: Int -> Int -> [(Text, Int)]
guideKinds specs summaries = [("allium", specs), ("chase", summaries)]

-- | An 'Asking' for the whole index, every server checked to be on the
-- LAN, the chat model's capacity worked out from its server, the
-- benchmark's measurements and the catalogue. The scope starts empty; a
-- caller that limits a question sets it.
askingFrom :: Client -> Catalogue -> Connection -> AskConfig -> (Text -> IO ()) -> IO (Either Text Asking)
askingFrom client cat conn c note = do
  r <- try @SomeException do
    (eLan, _, eBackend) <- either fail pure (lanServer c.embedAt)
    e <- either (fail . T.unpack) pure (embedder eLan eBackend.engine c.embedModel)
    (lan, ep, b) <- either fail pure (lanServer c.chatAt)
    rr <- case (c.rerankAt, c.rerankModel) of
      (Nothing, Nothing) -> pure Nothing
      (Just w, Just m) -> do
        (rLan, _, rBackend) <- either fail pure (lanServer w)
        Just <$> either (fail . T.unpack) pure (reranker rLan rBackend.engine m)
      _ -> fail "a reranker needs both its server and its model"
    served <- probeWindow client b.engine ep.url c.chatModel
    measured <- try @SomeException (measuredPath >>= readMeasured)
    let entry = case measured of
          Right (Right doc) -> measuredEntry doc ep.backend c.chatModel
          _ -> Nothing
    capRef <- newIORef (capacityFor b (lookupModel cat ep.backend c.chatModel) entry served)
    sc <- newIORef []
    pure
      Asking
        { client
        , conn
        , embedWith = e
        , chatTo = Chat {server = lan, engine = b.engine, model = c.chatModel}
        , capacity = capRef
        , depth = c.depth
        , sources = c.sources
        , rerankWith = rr
        , rerankDepth = c.rerankDepth
        , rerankMargin = c.rerankMargin
        , splitQuestions = c.splitQuestions
        , guides = guideKinds c.specSources c.chaseSources
        , maxWait = c.maxWait
        , scope = sc
        , note
        }
  pure (either (Left . T.pack . takeWhile (/= '\n') . displayException) Right r)
  where
    lanServer :: Text -> Either String (Lan, Endpoint, Backend)
    lanServer wanted =
      case [ep | ep <- cat.endpoints, endpointId ep == wanted] of
        [] -> Left (T.unpack wanted <> " is not an endpoint in the catalogue; known: " <> T.unpack (T.intercalate ", " (map endpointId cat.endpoints)))
        (ep : _) -> do
          lan <- either (Left . T.unpack) Right (onLan ep)
          b <- maybe (Left ("no backend " <> T.unpack ep.backend <> " in the catalogue")) Right (Map.lookup ep.backend cat.backends)
          Right (lan, ep, b)