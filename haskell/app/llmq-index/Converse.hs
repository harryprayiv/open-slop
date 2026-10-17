-- | Asking the index: one question, or a conversation kept in the database.
--
-- Part of llmq-index; Main describes the program, and "OpenSlop.Rag.Retrieve"
-- describes one turn. This module adds the terminal around it: the raw JSON
-- of the answer streams to stderr as progress, the answer is then printed
-- claim by claim with its sources, the sources follow with the cited ones
-- marked, and in a conversation every turn is stored under the session's
-- name, so
-- `llmq-index chat --session NAME` continues where it stopped, on any
-- machine that reaches the database.
--
-- The model's capacity is worked out once per session from its server, the
-- benchmark and the catalogue, and refined from the prompt token counts the
-- server reports, so how many sources fit grows with the model and the
-- hardware. The current figures are printed at the start.
module Converse
  ( Asking (..)
  , Selection (..)
  , select
  , answerWith
  , askOnce
  , converse
  ) where

import Control.Exception (AsyncException (..), throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (object, toJSON, (.=))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric (showFFloat)
import OpenSlop.Capacity (Capacity (..), describeCapacity, learn)
import OpenSlop.Http (Client)
import OpenSlop.Rag.Embed (Embedder)
import OpenSlop.Rag.Rerank (Reranker, rerank)
import OpenSlop.Rag.Retrieve
import OpenSlop.Rag.Store (Connection, Hit (..), addTurn, openSession, sessionTurns)
import System.Directory (makeAbsolute)
import System.IO (hFlush, hIsEOF, stderr, stdin, stdout)

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
  , maxWait :: Maybe Double
  , scope :: IORef [Text]
  }

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

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
  , kept :: [Hit]
  -- ^ those within the margin, at most --sources
  , packed :: [Hit]
  -- ^ those of 'kept' that fit the model's capacity; what the model is given
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
select :: Asking -> [(Text, Text)] -> Text -> IO (Either Text Selection)
select a history question = do
  cap <- readIORef a.capacity
  standalone <- condense a.client a.chatTo cap history question
  case standalone of
    Left e -> pure (Left e)
    Right q -> do
      when (q /= question) (say ("searching for: " <> q))
      parts <-
        if a.splitQuestions && mayHaveParts q
          then
            splitParts a.client a.chatTo cap q >>= \case
              Left e -> say ("not split (" <> e <> "); searching the question whole") >> pure [q]
              Right ps -> pure ps
          else pure [q]
      when (length parts > 1) (say ("searching " <> T.pack (show (length parts)) <> " parts: " <> T.intercalate " | " parts))
      sc <- readIORef a.scope
      let depthEach = if length parts > 1 then max 8 (a.rerankDepth `div` length parts) else a.rerankDepth
      scored <- traverse (scorePart a sc depthEach) parts
      case sequence scored of
        Left e -> pure (Left e)
        Right results
          | all (null . snd) results -> pure (Left (if null sc then "nothing in the index matches that question" else "nothing under " <> T.intercalate ", " sc <> " matches that question"))
          | otherwise -> do
              let found = map fst results
                  ranked = mergeParts (map snd results)
                  margin = maybe relevanceMargin (const a.rerankMargin) a.rerankWith
                  close = [h | (h, s) <- ranked, s >= negate margin]
                  kept = take a.sources close
                  packed = packSources cap a.maxWait (historyChars cap a.maxWait history question) kept
              say
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
                    <> T.pack (show (length packed))
                    <> " fit"
                )
              pure (Right Selection {query = q, searched = parts, found, ranked, kept, packed})

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
            say
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

-- | The parts' candidates as one list, best first, a chunk found by more
-- than one part kept once with its best score.
mergeParts :: [[(Hit, Double)]] -> [(Hit, Double)]
mergeParts perPart = sortOn (Down . snd) (Map.elems (Map.fromListWith better [(key h, (h, s)) | (h, s) <- concat perPart]))
  where
    key h = (h.path, h.lineFrom, h.lineTo)
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

-- | One turn on the terminal: select, then answer with the raw JSON
-- streaming to stderr, then the rendered answer and its sources.
turn :: Asking -> [(Text, Text)] -> Text -> IO (Either Text Answer)
turn a history question =
  select a history question >>= \case
    Left e -> pure (Left e)
    Right sel -> do
      r <- answerWith a history question sel.packed (\t -> TIO.hPutStr stderr t >> hFlush stderr)
      TIO.hPutStrLn stderr ""
      forM_ r \ans -> TIO.putStrLn ans.text >> showSources ans
      pure r

showSources :: Answer -> IO ()
showSources ans = do
  TIO.putStrLn ""
  forM_ (zip [1 :: Int ..] ans.sources) \(n, h) ->
    TIO.putStrLn
      ( (if n `elem` ans.cited then "* [" else "  [")
          <> T.pack (show n)
          <> "] "
          <> h.path
          <> ":"
          <> T.pack (show h.lineFrom)
          <> "-"
          <> T.pack (show h.lineTo)
          <> (if T.null h.heading then "" else "  " <> h.heading)
      )
  when (null ans.claims) (say "the answer makes no claim from your files")
  let open = [p.ask | p <- ans.parts, null p.claims]
  unless (null ans.claims || null open) (say ("not answered from your files: " <> T.intercalate "; " open))
  unless (null ans.invented) (say ("the answer cites sources it was not given: " <> T.pack (show ans.invented)))

askOnce :: Asking -> Text -> IO Bool
askOnce a q = do
  readIORef a.capacity >>= say . describeCapacity
  turn a [] q >>= \case
    Left e -> say e >> pure False
    Right _ -> pure True

-- | A conversation on the terminal, stored under the session's name.
converse :: Asking -> Maybe Text -> IO ()
converse a named = do
  name <- maybe (T.pack . formatTime defaultTimeLocale "%Y-%m-%d-%H%M%S" <$> getZonedTime) pure named
  sid <- openSession a.conn name
  earlier <- sessionTurns a.conn sid
  cap <- readIORef a.capacity
  say ("session " <> name <> (if null earlier then ", new" else ", " <> T.pack (show (length earlier)) <> " earlier turns"))
  say (describeCapacity cap)
  say "/sources shows the last answer's sources in full, /under PATH limits the search, /under alone clears it, /scope shows it, /new starts another session, /quit leaves; ctrl-c stops an answer"
  lastAnswer <- newIORef Nothing
  loop sid name lastAnswer
  where
    loop sid name lastAnswer = do
      TIO.putStr "you> " >> hFlush stdout
      eof <- hIsEOF stdin
      if eof
        then pure ()
        else do
          line <- T.strip <$> TIO.getLine
          case T.words line of
            [] -> loop sid name lastAnswer
            ["/quit"] -> pure ()
            ["/exit"] -> pure ()
            ["/new"] -> converse a Nothing
            ["/scope"] -> do
              sc <- readIORef a.scope
              say (if null sc then "searching everything" else "searching under " <> T.intercalate ", " sc)
              loop sid name lastAnswer
            ["/under"] -> writeIORef a.scope [] >> say "searching everything" >> loop sid name lastAnswer
            ("/under" : ps) -> do
              absolute <- traverse (fmap T.pack . makeAbsolute . T.unpack) ps
              writeIORef a.scope absolute
              say ("searching under " <> T.intercalate ", " absolute)
              loop sid name lastAnswer
            ["/sources"] -> do
              readIORef lastAnswer >>= \case
                Nothing -> say "no answer yet"
                Just ans -> forM_ (zip [1 :: Int ..] ans.sources) \(n, h) -> do
                  TIO.putStrLn ("[" <> T.pack (show n) <> "] " <> h.path <> ":" <> T.pack (show h.lineFrom) <> "-" <> T.pack (show h.lineTo))
                  TIO.putStrLn h.body
                  TIO.putStrLn ""
              loop sid name lastAnswer
            (cmd : _) | "/" `T.isPrefixOf` cmd -> say ("unknown command " <> cmd) >> loop sid name lastAnswer
            _ -> do
              history <- sessionTurns a.conn sid
              turn a history line >>= \case
                Left e -> say e
                Right ans -> do
                  addTurn a.conn sid "user" line Nothing Nothing
                  addTurn
                    a.conn
                    sid
                    "assistant"
                    ans.text
                    (Just (toJSON [object ["path" .= h.path, "lineFrom" .= h.lineFrom, "lineTo" .= h.lineTo, "heading" .= h.heading] | h <- ans.sources]))
                    (Just a.chatTo.model)
                  writeIORef lastAnswer (Just ans)
              loop sid name lastAnswer