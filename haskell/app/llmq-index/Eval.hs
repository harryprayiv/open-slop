-- | Measuring retrieval and answers against questions whose answers are
-- known.
--
-- Part of llmq-index; see Main. The margins, --sources and the reranker's
-- depth were first set by hand from a few questions on one corpus. This
-- module replaces that with numbers: for each question in an evaluation
-- file it reports where the chunk that answers it ranked, whether it was
-- kept and sent to the model, whether a claim cited it, and whether the
-- parts the files cannot answer came back as gaps.
--
-- ============================================================================
-- THE FILE
-- ============================================================================
--
--   { "cases": [
--       { "question": "what status code does refuseWrite give for SaleNotOpen?",
--         "expect": [ { "path": "backend/src/Service/Transaction.hs",
--                       "contains": "refuseWrite (SaleNotOpen" } ],
--         "missing": 0 } ] }
--
-- "expect" lists the chunks that answer the question, one for each part
-- that can be answered. A hit matches when its path contains "path" and
-- its text contains "contains", ignoring case. "contains" may also be a
-- list of phrases, any one of which matches, for an answer stated in more
-- than one place (a module's header comment and the definition it
-- describes): the first run of these sets showed the reranker choosing the
-- header, which answers the question as well, and the case counting it as
-- a miss.
--
-- A phrase and a path are used rather than line numbers because line
-- numbers move with every edit and the file would go stale; each phrase
-- should be short and specific, so that it falls inside one chunk.
--
-- "missing" is how many parts of the question the files do not answer
-- (default 0). A case with expect [] and missing 1 asks something the
-- index cannot answer at all.
--
-- ============================================================================
-- WHAT IS REPORTED
-- ============================================================================
--
-- For each expected chunk: its rank among the scored candidates (the
-- reranker's order with a reranker, similarity otherwise), how far its
-- score is below the best (the margin that would have kept it), whether it
-- was kept, sent, and cited. For the answer: the parts, and how many are
-- gaps against how many should be. The totals at the end are what the
-- margins should be chosen from: the largest "below best" among chunks
-- that answer is the smallest margin that keeps them all.
--
-- When an expected chunk did not rank first, the candidates that ranked
-- above it are printed with their scores, so a wrong case, a chunk that
-- should have been left out of the index, and a retrieval miss can be told
-- apart.
--
-- With a reranker, the summary ends with a margin sweep: for each margin,
-- how many expected chunks it would have kept and how many sources it
-- would have sent on average, computed from the scores this run already
-- has, so choosing --rerank-margin needs no second run.
--
-- --retrieval-only stops before the chat model, which makes a run several
-- times faster and is enough to set the margins and the depth.
module Eval
  ( EvalOpts (..)
  , runEval
  ) where

import Control.Monad (forM, forM_, when)
import Data.Aeson (FromJSON (..), withObject, (.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.List (findIndex)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Converse (Asking (..), Selection (..), answerWith, select)
import Numeric (showFFloat)
import OpenSlop.Rag.Retrieve (Answer (..), Part (..))
import OpenSlop.Rag.Store (Hit (..), chunksMatching)
import System.IO (stderr)

data EvalOpts = EvalOpts
  { file :: FilePath
  , retrievalOnly :: Bool
  }

data Expect = Expect
  { path :: Text
  , contains :: [Text]
  -- ^ any one of these
  }

instance FromJSON Expect where
  parseJSON = withObject "expected chunk" \o -> do
    p <- o .: "path"
    c <- o .: "contains"
    phrases <- case c of
      Aeson.String t -> pure [t]
      _ -> parseJSON c
    pure (Expect p phrases)

data Case = Case
  { question :: Text
  , expect :: [Expect]
  , missing :: Int
  }

instance FromJSON Case where
  parseJSON = withObject "case" \o ->
    Case <$> o .: "question" <*> o .:? "expect" .!= [] <*> o .:? "missing" .!= 0

newtype Cases = Cases [Case]

instance FromJSON Cases where
  parseJSON = withObject "evaluation" \o -> Cases <$> o .: "cases"

-- | What happened to one expected chunk.
data Fate = Fate
  { indexed :: Int
  -- ^ chunks in the index that match; 0 means the case itself is wrong
  , rank :: Maybe Int
  -- ^ 1-based, among the scored candidates; Nothing when the search did
  -- not find it at all
  , below :: Maybe Double
  -- ^ the best candidate's score minus this one's
  , kept :: Bool
  , sent :: Bool
  , cited :: Maybe Bool
  -- ^ Nothing when no answer was asked for
  }

-- | One question's candidates: the first few as "path:lines" with their
-- scores, and how far below the best each candidate's score is, for the
-- margin sweep.
data Field = Field
  { top :: [(Text, Double)]
  , belowAll :: [Double]
  }

-- | What happened to one question's answer.
data Outcome = Outcome
  { parts :: Int
  , gaps :: Int
  , seconds :: Double
  }

matches :: Expect -> Hit -> Bool
matches e h =
  T.toLower e.path `T.isInfixOf` T.toLower h.path
    && any (\c -> T.toLower c `T.isInfixOf` T.toLower (h.heading <> "\n" <> h.body)) e.contains

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

fixed :: Int -> Double -> Text
fixed n x = T.pack (showFFloat (Just n) x "")

runEval :: Asking -> EvalOpts -> IO Bool
runEval a o = do
  raw <- BS.readFile o.file
  case Aeson.eitherDecodeStrict raw of
    Left err -> say ("cannot read " <> T.pack o.file <> ": " <> T.pack err) >> pure False
    Right (Cases cs) -> do
      results <- forM (zip [1 :: Int ..] cs) \(n, c) -> do
        TIO.putStrLn ("[" <> tshow n <> "/" <> tshow (length cs) <> "] " <> c.question)
        r <- one a o c
        case r of
          Left e -> TIO.putStrLn ("  error: " <> e) >> pure Nothing
          Right (fates, field, outcome) -> do
            forM_ (zip c.expect fates) \(e, f) -> TIO.putStrLn ("  " <> describeFate e f)
            let firstRank = minimum (maxBound : [k | Just k <- map (.rank) fates])
            when (not (null fates) && firstRank /= 1) $
              forM_ (take (min 3 (firstRank - 1)) field.top) \(where_, s) ->
                TIO.putStrLn ("    above it: " <> fixed 2 s <> "  " <> where_)
            forM_ outcome \out ->
              TIO.putStrLn
                ( "  answer: "
                    <> tshow out.parts
                    <> " parts, "
                    <> tshow out.gaps
                    <> " gaps, expected "
                    <> tshow c.missing
                    <> (if out.gaps == c.missing then "" else "  WRONG")
                    <> ", "
                    <> fixed 1 out.seconds
                    <> " s"
                )
            pure (Just (c, fates, field, outcome))
      summarise (isJust a.rerankWith) a.sources (catMaybes results) (length cs)
      pure True

one :: Asking -> EvalOpts -> Case -> IO (Either Text ([Fate], Field, Maybe Outcome))
one a o c =
  select a [] c.question >>= \case
    Left e
      | null c.expect -> pure (Right ([], Field [] [], if o.retrievalOnly then Nothing else Just Outcome {parts = 0, gaps = c.missing, seconds = 0}))
      | otherwise -> pure (Left e)
    Right sel -> do
      answered <-
        if o.retrievalOnly
          then pure (Right Nothing)
          else do
            t0 <- getCurrentTime
            r <- answerWith a [] c.question sel.packed (const (pure ()))
            t1 <- getCurrentTime
            pure (fmap (\ans -> Just (ans, realToFrac (diffUTCTime t1 t0))) r)
      case answered of
        Left e -> pure (Left e)
        Right ans -> do
          counts <- traverse (\e -> sum <$> traverse (chunksMatching a.conn e.path) e.contains) c.expect
          let best = case sel.ranked of
                [] -> 0
                ((_, s) : _) -> s
              fate (e, inIndex) =
                let at = findIndex (matches e . fst) sel.ranked
                    hit = fmap (\i -> sel.ranked !! i) at
                    sentAt = findIndex (matches e) sel.packed
                 in Fate
                      { indexed = inIndex
                      , rank = fmap (+ 1) at
                      , below = fmap (\(_, s) -> best - s) hit
                      , kept = any (matches e) sel.kept
                      , sent = isJust sentAt
                      , cited = fmap (\(an, _) -> maybe False (\i -> (i + 1) `elem` an.cited) sentAt) ans
                      }
              outcome =
                fmap
                  ( \(an, secs) ->
                      Outcome {parts = length an.parts, gaps = length [p | p <- an.parts, null p.claims], seconds = secs}
                  )
                  ans
              field =
                Field
                  { top = [(h.path <> ":" <> tshow h.lineFrom <> "-" <> tshow h.lineTo, s) | (h, s) <- take 3 sel.ranked]
                  , belowAll = [best - s | (_, s) <- sel.ranked]
                  }
          pure (Right (map fate (zip c.expect counts), field, outcome))

describeFate :: Expect -> Fate -> Text
describeFate e f =
  e.path
    <> " \""
    <> T.intercalate "\" or \"" e.contains
    <> "\": "
    <> case f.rank of
      Nothing
        | f.indexed == 0 -> "NOT IN THE INDEX: the file was not ingested, or the phrase is not inside one chunk; fix the case"
        | otherwise -> "NOT AMONG THE CANDIDATES scored (" <> tshow f.indexed <> " matching chunks in the index; raise --depth, or --rerank-depth with a reranker)"
      Just r ->
        "rank "
          <> tshow r
          <> maybe "" (\b -> ", " <> fixed 2 b <> " below best") f.below
          <> (if f.kept then ", kept" else ", DROPPED")
          <> (if f.sent then ", sent" else if f.kept then ", did not fit" else "")
          <> case f.cited of
            Nothing -> ""
            Just True -> ", cited"
            Just False -> if f.sent then ", NOT CITED" else ""

summarise :: Bool -> Int -> [(Case, [Fate], Field, Maybe Outcome)] -> Int -> IO ()
summarise reranked most rs total = do
  let allFates = concat [fs | (_, fs, _, _) <- rs]
      fates = [f | f <- allFates, f.indexed > 0]
      wrong = length allFates - length fates
      n = length fates
      count p = length (filter p fates)
      ratio k = tshow k <> "/" <> tshow n
      belows = catMaybes [f.below | f <- fates]
      answered = [(c, out) | (c, _, _, Just out) <- rs]
      gapsRight = length [() | (c, out) <- answered, out.gaps == c.missing]
      partial = [(c, out) | (c, out) <- answered, c.missing > 0]
  TIO.putStrLn ""
  TIO.putStrLn (tshow (length rs) <> " of " <> tshow total <> " questions ran")
  when (wrong > 0) $
    TIO.putStrLn (tshow wrong <> " expected chunks are not in the index and are left out of the counts below; fix those cases")
  TIO.putStrLn ("expected chunks among the candidates scored: " <> ratio (count (isJust . (.rank))))
  TIO.putStrLn ("  ranked first: " <> ratio (count ((== Just 1) . (.rank))))
  TIO.putStrLn ("  kept by the margin: " <> ratio (count (.kept)))
  TIO.putStrLn ("  sent to the model: " <> ratio (count (.sent)))
  when (any (isJust . (.cited)) fates) $
    TIO.putStrLn ("  cited: " <> ratio (count ((== Just True) . (.cited))))
  when (not (null belows)) $
    TIO.putStrLn
      ( "  below best: largest "
          <> fixed 2 (maximum belows)
          <> ", mean "
          <> fixed 2 (sum belows / fromIntegral (length belows))
          <> "; a margin under the largest drops at least one answering chunk"
      )
  when (reranked && not (null belows)) $ do
    TIO.putStrLn ("margin sweep (--rerank-margin, with --sources " <> tshow most <> "):")
    forM_ [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0] \m -> do
      let keeps = length [() | f <- fates, Just b <- [f.below], Just k <- [f.rank], b <= m, k <= most]
          sent = [min most (length (filter (<= m) fl.belowAll)) | (_, fs, fl, _) <- rs, not (null fs)]
          meanSent = fromIntegral (sum sent) / fromIntegral (max 1 (length sent)) :: Double
      TIO.putStrLn
        ( "  "
            <> fixed 1 m
            <> ": keeps "
            <> ratio keeps
            <> " expected chunks, sends "
            <> fixed 1 meanSent
            <> " sources on average"
        )
    TIO.putStrLn "  (an expected chunk counts as kept when it is within the margin and among the best --sources)"
  when (not (null answered)) $ do
    TIO.putStrLn ("answers with the right number of gaps: " <> tshow gapsRight <> "/" <> tshow (length answered))
    when (not (null partial)) $
      TIO.putStrLn
        ( "  of questions the files cannot fully answer: "
            <> tshow (length [() | (c, out) <- partial, out.gaps == c.missing])
            <> "/"
            <> tshow (length partial)
        )
    TIO.putStrLn ("mean answer time: " <> fixed 1 (sum [out.seconds | (_, out) <- answered] / fromIntegral (length answered)) <> " s")