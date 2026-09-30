-- | The measurement protocol for one model.
--
-- Part of llmq-bench; Main's header says what the figures mean and how they
-- are meant to be used. This module is the order of operations.
--
-- ============================================================================
-- THE ORDER
-- ============================================================================
--
--   1. Wait for an idle machine under the starting temperature.
--   2. Facts and window from the server.
--   3. Load and warmup, loadReps times, each starting cool. On ollama every
--      other model is unloaded first, then this one, and each repetition
--      times the load alone (an empty /api/generate), then at once one
--      short request (its excess over the next two is the warmup), then two
--      more. With --control, repetitions alternate between a load with the
--      page cache dropped (from the SD card) and one without (from RAM).
--      On llama-server with --control the load is a restart timed to a
--      healthy /health. On hailo-ollama a load is switching to this model
--      from another, which cannot be separated from its first request.
--   4. The grid: a prompt of each size, answered with outTokens tokens,
--      streamed. Sizes are visited round-robin, one repetition of each per
--      round, and every trial waits first for an idle machine under the
--      starting temperature (Conditions.waitCool), so every trial starts
--      from the same state. Each prompt starts with a new nonce, so no
--      prefix cache can serve it.
--   5. Reuse: the largest prompt sent once to fill the cache, then again
--      with a different short question on the end each time, each paced
--      like the grid. This is the pattern of many questions over one
--      bundle, and its ttft against the cold ttft at the same size is what
--      the cache is worth.
--   6. Schema: whether a JSON Schema request comes back in the schema.
--   7. Restraint: the eight probes, once each; temperature 0 makes them
--      deterministic, so repeating them adds nothing, and when the served
--      model is the one measured before (same fingerprint) the earlier
--      answers are carried over unless --reprobe is given.
--
-- ============================================================================
-- REGIMES, AND WHEN A SIZE IS DONE
-- ============================================================================
--
-- Each trial is burst, sustained or contended by what the machine did
-- while it ran (Conditions). A size is done when it has minReps burst
-- trials whose ttft and decode rate both have a 95% interval within
-- `target` of the mean; or, when none of its trials ran unthrottled (a
-- long prompt on bare cooling heats the Pi into throttling by itself),
-- when it has minReps sustained trials that are that precise. Otherwise it repeats
-- to maxReps or the time budget. Contended trials never count.
--
-- A size's headline figure is its burst figure when it has minReps burst
-- trials, else its sustained figure, and its row says which. Both figures
-- are reported when both exist, with every trial's own clock, temperature
-- and wait, so nothing about how a number was taken is left out.
--
-- ============================================================================
-- WHAT COMES OUT, FOR DECISIONS
-- ============================================================================
--
--   predict.burst      ttft = a + b*k + c*k^2 and decode = d0 + d1*k, k the
--                      prompt in thousands of tokens, fitted over burst
--                      trials: a request to an idle machine.
--   predict.sustained  the same over sustained trials: a request after the
--                      machine has been working long enough to throttle.
--   A whole answer of m tokens to a k-thousand-token prompt then takes about
--   ttft(k) + (m - 1) / decode(k), from a cold cache. With the prompt's
--   prefix cached, use reuse.ttft in place of ttft(k).
--
-- ============================================================================
-- PROBLEMS AND OBSERVATIONS
-- ============================================================================
--
-- `problems` are failures of the measurement: a request that failed, a
-- prompt the server cut short. They make the entry due for measuring again.
-- `observations` are how the model behaved: stopping early at some prompt
-- size, as qwen2.5:3b did at 4,000 tokens on 2026-09-30. They are facts
-- about the model, and measuring again would find them again.
module Protocol
  ( Config (..)
  , Target (..)
  , Result (..)
  , measureModel
  , unloadAll
  ) where

import Conditions
import Control (Control, dropCaches, llamaServer)
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import OpenSlop.Catalogue
import OpenSlop.Http
import OpenSlop.Measured (currentProtocol)
import Probe
import Restraint (refuses, restraintProbes)
import Stats
import System.IO (stderr)
import Text.Printf (printf)

data Config = Config
  { minReps :: Int
  , maxReps :: Int
  , target :: Double
  , sizes :: [Int]
  , outTokens :: Int
  , loadReps :: Int
  , budgetSecs :: Double
  , probes :: Bool
  , timeoutSecs :: Int
  , control :: Maybe Control
  , fromDisk :: Bool
  , coolTo :: Double
  -- ^ every timed request waits for the machine to be under this, in C
  , coolTimeout :: Double
  , sampler :: Maybe Sampler
  , client :: Client
  }

-- | The model to measure and what it is measured through.
data Target = Target
  { ep :: Endpoint
  , backend :: Backend
  , name :: Text
  , numCtx :: Maybe Int
  -- ^ ollama's num_ctx: the window llmq uses for this model
  , others :: [Text]
  -- ^ other models on the same endpoint, for switching away on hailo
  , priorRestraint :: Maybe (Value, Text)
  -- ^ restraint results from an earlier measurement of the same weights,
  -- and the day they were taken
  }

data Result = Result
  { tokPerSec :: Maybe Double
  , measured :: [(Key.Key, Value)]
  }

-- | A trial with what the machine was doing while it ran.
data Judged = Judged
  { trial :: Trial
  , verdict :: Verdict
  , waited :: Double
  , startTemp :: Maybe Double
  }

regimeOf :: Judged -> Regime
regimeOf j = j.verdict.regime

measureModel :: Config -> Target -> IO Result
measureModel cfg tg = do
  tStart <- now
  problemsRef <- newIORef []
  earlyRef <- newIORef (Map.empty :: Map.Map Int [Int])
  let problem t = say ("  PROBLEM " <> t) >> modifyIORef' problemsRef (<> [t])
      eng = tg.backend.engine

  -- 1. idle and cool
  (waitedStart, quiet, _) <- case cfg.sampler of
    Nothing -> threadDelay 30000000 >> pure (30, False, Nothing)
    Just s -> waitQuiet s cfg.coolTo cfg.coolTimeout
  say (T.pack (printf "  waited %.0f s for an idle machine under %.0f C%s" waitedStart cfg.coolTo (if quiet then "" else ", and gave up" :: String)))

  -- 2. facts and window
  facts <- factsOf cfg.client tg
  trained <- windowOf cfg.client tg
  let window = case (trained, tg.numCtx) of
        (Just t, Just c) -> Just (min t c)
        (t, c) -> maybe t Just c
      limit = fromMaybe tg.backend.ctx window
      sizesOk =
        [ s
        | s <- cfg.sizes
        , s + cfg.outTokens + 64 <= limit
        , eng /= HailoOllama || s <= 1024
        ]
      short = Request "Reply with the word ok." 1 False tg.numCtx
      paced = timed cfg tg True
      immediate = timed cfg tg False
      cool = case cfg.sampler of
        Just s -> () <$ waitCool s cfg.coolTo cfg.coolTimeout
        Nothing -> pure ()

  -- 3. load and warmup
  loadMem <- newIORef []
  loadDisk <- newIORef []
  serverStart <- newIORef []
  combined <- newIORef []
  warmups <- newIORef []
  overheads <- newIORef []
  let firstAndSteady afterLoad = do
        f <- immediate short
        s1 <- immediate short
        s2 <- immediate short
        case (f, s1, s2) of
          (Right a, Right b, Right c) -> do
            let steady = [b.trial.total, c.trial.total]
            modifyIORef' overheads (<> steady)
            when afterLoad $ forM_ (median steady) \m -> modifyIORef' warmups (<> [a.trial.total - m])
            pure (Just (a.trial.total, median steady))
          _ -> problem "a short request after loading failed" >> pure Nothing
  case eng of
    Ollama -> do
      let modes = if cfg.fromDisk && isJust cfg.control then [True, False] else [False]
      diskOk <- newIORef True
      forM_ [1 .. cfg.loadReps] \_ -> forM_ modes \disk -> do
        unloadAll cfg.client tg.ep
        cool
        dropped <-
          if disk
            then case cfg.control of
              Just c -> do
                okBefore <- readIORef diskOk
                if okBefore
                  then
                    dropCaches c >>= \case
                      Right () -> pure True
                      Left e -> problem ("page cache not dropped, so no load from disk: " <> e) >> writeIORef diskOk False >> pure False
                  else pure False
              Nothing -> pure False
            else pure True
        when (not disk || dropped) do
          t0 <- now
          r <- postJsonWithin (Just cfg.timeoutSecs) cfg.client NoAuth tg.ep.url "/api/generate" (object (["model" .= tg.name, "keep_alive" .= ("30m" :: Text)] <> ["options" .= object ["num_ctx" .= c] | Just c <- [tg.numCtx]]))
          t1 <- now
          case r of
            Left f -> problem ("load failed: " <> describeFailure f)
            Right _ -> do
              modifyIORef' (if disk then loadDisk else loadMem) (<> [t1 - t0])
              _ <- firstAndSteady True
              pure ()
    LlamaServer -> case cfg.control of
      Just c -> forM_ [1 .. cfg.loadReps] \_ -> do
        cool
        t0 <- now
        llamaServer c "restart" >>= \case
          Left e -> problem ("llama-server restart failed: " <> e)
          Right () -> do
            ok <- waitHealthy cfg.client tg.ep.url 600
            t1 <- now
            if ok
              then modifyIORef' serverStart (<> [t1 - t0]) >> firstAndSteady True >> pure ()
              else problem "llama-server did not become healthy within 600 s of a restart"
      Nothing -> forM_ [1 .. cfg.loadReps] \_ -> cool >> firstAndSteady False
    HailoOllama -> forM_ [1 .. cfg.loadReps] \_ -> do
      case tg.others of
        (o : _) -> do
          _ <- streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend o short
          cool
          r <- firstAndSteady True
          forM_ r \(first, steady) -> forM_ steady \m -> modifyIORef' combined (<> [first - m])
        [] -> cool >> () <$ firstAndSteady False

  -- 4. the grid
  tGrid <- now
  let deadline = tStart + cfg.budgetSecs
  grid <- newIORef (Map.fromList [(s, []) | s <- sizesOk])
  counter <- newIORef (0 :: Int)
  let done' s = sizeDone cfg . Map.findWithDefault [] s <$> readIORef grid
      round' rep = do
        pending <- filterM' (fmap not . done') sizesOk
        forM_ pending \s -> do
          ts <- Map.findWithDefault [] s <$> readIORef grid
          t <- now
          let expected = fromMaybe 0 (median (map (\j -> j.trial.total + j.waited) ts))
          if rep > cfg.minReps && t + expected > deadline
            then pure ()
            else do
              k <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
              r <- paced (Request (filler tg.backend s ("grid " <> T.pack (show k) <> " " <> T.pack (show t))) cfg.outTokens False tg.numCtx)
              case r of
                Left e -> problem (T.pack (show s) <> "-token prompt: " <> e)
                Right j -> do
                  forM_ j.trial.promptTokens \pt ->
                    when (fromIntegral pt < 0.8 * (fromIntegral s :: Double)) $
                      problem (T.pack (printf "%d-token prompt: the server read only %d tokens of it" s pt))
                  let got = fromMaybe j.trial.pieces j.trial.completionTokens
                  when (got < cfg.outTokens `div` 2) $
                    modifyIORef' earlyRef (Map.insertWith (flip (<>)) s [got])
                  modifyIORef' grid (Map.insertWith (flip (<>)) s [j])
                  sayTrial s j
        pure (not (null pending))
  let rounds rep
        | rep > cfg.maxReps = pure ()
        | otherwise = do
            t <- now
            more <- if rep > cfg.minReps && t >= deadline then pure False else round' rep
            when more (rounds (rep + 1))
  rounds 1
  gridDone <- readIORef grid

  -- 5. reuse
  reuseRef <- newIORef []
  case reverse sizesOk of
    [] -> pure ()
    (big : _) -> do
      bundleNonce <- now
      let bundle = fillerBody tg.backend big ("bundle " <> T.pack (show bundleNonce))
          ask i = paced (Request (bundle <> "\n\nQuestion " <> T.pack (show (i :: Int)) <> ": reply with the word ok.") 1 False tg.numCtx)
      _ <- ask 0
      let loop i
            | i > cfg.maxReps = pure ()
            | otherwise = do
                js <- readIORef reuseRef
                t <- now
                let xs = mapMaybe (.trial.ttft) [j | j <- js, regimeOf j /= Contended]
                    finished = i > cfg.minReps && (maybe False (<= cfg.target) (relHalfWidth xs) || t >= deadline + 600)
                unless finished do
                  ask i >>= \case
                    Left e -> problem ("reuse: " <> e)
                    Right j -> modifyIORef' reuseRef (<> [j])
                  loop (i + 1)
      loop 1

  -- 6. schema
  schemaVerdict <-
    if eng == HailoOllama
      then pure "not asked: hailo-ollama cannot constrain output"
      else
        streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend tg.name (Request "What is two plus two? Reply in the requested JSON." 40 True tg.numCtx) >>= \case
          Left e -> pure ("rejected: " <> T.take 120 e)
          Right t -> pure case Aeson.decode (BL.fromStrict (TE.encodeUtf8 t.text)) :: Maybe Value of
            Just (Object km) | KeyMap.member "answer" km -> "honoured"
            _ -> "ignored: the answer did not match the schema"

  -- 7. restraint
  restraint <- case (cfg.probes, tg.priorRestraint) of
    (False, _) -> pure Null
    (True, Just (Object prior, day)) -> do
      say ("  restraint carried over from " <> day <> ": the same weights answer deterministically")
      pure (Object (KeyMap.insert "carriedFrom" (String day) prior))
    (True, _) -> do
      -- 120 tokens is enough for any answer's opening, which is all the
      -- verdict reads. A reasoning model can spend all of it thinking and
      -- give no answer, so that one probe is asked again with room for the
      -- think block and the answer after it.
      let probe prompt budget = streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend tg.name (Request prompt budget False tg.numCtx)
      results <- forM restraintProbes \(probeName, prompt) -> do
        first <- probe prompt 120
        r <- case first of
          Right t | T.null (T.strip t.text), t.thinking > 0 -> probe prompt 1024
          _ -> pure first
        pure case r of
          Left e -> (probeName, False, 0, "no answer: " <> T.take 120 e)
          Right t -> (probeName, refuses probeName t.text, t.total, T.take 300 (T.strip t.text))
      pure
        ( object
            [ "asked" .= length results
            , "refused" .= length [() | (_, True, _, _) <- results]
            , "refusedWhich" .= [p | (p, True, _, _) <- results]
            , "probes" .= [object ["probe" .= p, "refused" .= r, "seconds" .= r2 secs, "answer" .= a] | (p, r, secs, a) <- results]
            ]
        )

  tEnd <- now
  everything <- maybe (pure []) (\s -> samplesBetween s tStart tEnd) cfg.sampler
  seen <- maybe (pure False) observed cfg.sampler
  problems <- readIORef problemsRef
  early <- readIORef earlyRef
  lm <- readIORef loadMem
  ld <- readIORef loadDisk
  ss <- readIORef serverStart
  cb <- readIORef combined
  wu <- readIORef warmups
  oh <- readIORef overheads
  ru <- readIORef reuseRef

  let overheadMed = fromMaybe 0 (median oh)
      allGrid = concat (Map.elems gridDone)
      promptTokOf s js = case mapMaybe (.trial.promptTokens) js of
        [] -> (s, True)
        xs -> (round (fromMaybe (fromIntegral s) (median (map fromIntegral xs)) :: Double), False)
      ttftsOf = mapMaybe (.trial.ttft)
      ratesOf = mapMaybe (decodeRate . (.trial))
      pairJSON js =
        if null js
          then Null
          else object ["trials" .= length js, "ttft" .= fmap summaryJSON (summarise (ttftsOf js)), "decodeTokPerSec" .= fmap summaryJSON (summarise (ratesOf js))]
      rows =
        [ (s, reg, hs, js)
        | (s, js) <- Map.toList gridDone
        , let (reg, hs) = headline cfg js
        ]
      prefillRows =
        [ object
            [ "promptTokens" .= pt
            , "tokensEstimated" .= est
            , "regime" .= reg
            , "seconds" .= r2 m
            , "tokPerSec" .= r2 (fromIntegral pt / max 0.01 (m - overheadMed))
            , "ttft" .= summaryJSON sm
            , "burst" .= pairJSON [j | j <- js, regimeOf j == Burst]
            , "sustained" .= pairJSON [j | j <- js, regimeOf j == Sustained]
            , "contendedTrials" .= length [() | j <- js, regimeOf j == Contended]
            , "trials" .= map trialJSON js
            ]
        | (s, reg, hs, js) <- rows
        , Just sm <- [summarise (ttftsOf hs)]
        , let m = sm.median'
        , let (pt, est) = promptTokOf s js
        ]
      byDepth =
        [ (pt, reg, sm)
        | (s, reg, hs, js) <- rows
        , Just sm <- [summarise (ratesOf hs)]
        , let (pt, _) = promptTokOf s js
        ]
      shallowDecode = (\(_, _, sm) -> sm.median') <$> listToMaybe (sortOn (\(pt, _, _) -> pt) byDepth)
      fitsFor reg =
        let js = [j | j <- allGrid, regimeOf j == reg]
            kOf j = fromIntegral (fromMaybe 0 j.trial.promptTokens) / 1000
            ttftPts = [(kOf j, t) | j <- js, Just t <- [j.trial.ttft], isJust j.trial.promptTokens]
            ratePts = [(kOf j, r) | j <- js, Just r <- [decodeRate j.trial], isJust j.trial.promptTokens]
            ttftFit = case fitPoly 2 ttftPts of
              Just f | length ttftPts >= 4 -> Just ("a + b*k + c*k^2, k = prompt tokens / 1000" :: Text, f)
              _ -> ("a + b*k, k = prompt tokens / 1000",) <$> fitPoly 1 ttftPts
            rateFit = ("d0 + d1*k, k = prompt tokens / 1000" :: Text,) <$> fitPoly 1 ratePts
            asJSON = fmap (\(form, f) -> object ["form" .= form, "fit" .= fitJSON f])
         in if null js
              then Null
              else object ["ttftSeconds" .= asJSON ttftFit, "decodeTokPerSec" .= asJSON rateFit, "trials" .= length js]
      bigRow = listToMaybe (reverse rows)
      coldAtBig = bigRow >>= \(_, _, hs, _) -> median (ttftsOf hs)
      reuseClean = [j | j <- ru, regimeOf j /= Contended]
      countRegime r = length [() | j <- allGrid <> ru, regimeOf j == r]
      loadHeadline = case (median lm, median ss, median cb) of
        (Just m, _, _) -> Just m
        (_, Just s, _) -> Just s
        (_, _, Just c) -> Just c
        _ -> Nothing
      loadMethod :: Text
      loadMethod = case eng of
        Ollama -> "every other model unloaded, then an empty /api/generate timed until the model is resident" <> (if null ld then "; the page cache was not dropped, so these are loads from RAM" else "; fromDisk after dropping the page cache, fromMemory without")
        LlamaServer -> if null ss then "llama-server loads at start and --control was not given, so its start was not timed" else "systemctl restart timed until /health answers ok"
        HailoOllama -> if null cb then "no other hailo model to switch from, so not measured" else "switched from another model, then the first request's time over the steady request time: load and warmup together"
      observations =
        [ T.pack (printf "%d-token prompt: stopped early in %d of %d trials, after %s of %d tokens" s (length ns) (length (Map.findWithDefault [] s gridDone)) (T.unpack (T.intercalate ", " (map (T.pack . show) ns))) cfg.outTokens)
        | (s, ns) <- Map.toList early
        ]
      conditions =
        object
          [ "observed" .= seen
          , "coolToC" .= cfg.coolTo
          , "waitedForIdleAtStartSeconds" .= r2 waitedStart
          , "idleAtStart" .= quiet
          , "waitedBetweenTrialsSeconds" .= r2 (sum [j.waited | j <- allGrid <> ru])
          , "trials" .= object ["burst" .= countRegime Burst, "sustained" .= countRegime Sustained, "contended" .= countRegime Contended]
          , "whole" .= summaryOf everything
          ]
      sm' = fmap summaryJSON . summarise
  say
    ( T.pack
        ( printf
            "  decode %s tok/s, load %s s, %d grid trials (%d burst, %d sustained, %d contended), %.0f min"
            (maybe "-" (printf "%.2f") shallowDecode :: String)
            (maybe "-" (printf "%.1f") loadHeadline :: String)
            (length allGrid)
            (length [() | j <- allGrid, regimeOf j == Burst])
            (length [() | j <- allGrid, regimeOf j == Sustained])
            (length [() | j <- allGrid, regimeOf j == Contended])
            ((tEnd - tStart) / 60)
        )
    )
  forM_ observations \o -> say ("  observed: " <> o)
  when (tGrid - tStart > cfg.budgetSecs) (problem "the load measurements alone used the whole time budget")
  pure
    Result
      { tokPerSec = r2 <$> shallowDecode
      , measured =
          [ ("window", toJSON window)
          , ("trainedWindow", toJSON trained)
          , ("numCtx", toJSON tg.numCtx)
          , ( "protocol"
            , object
                [ "version" .= currentProtocol
                , "minReps" .= cfg.minReps
                , "maxReps" .= cfg.maxReps
                , "target" .= cfg.target
                , "sizes" .= sizesOk
                , "outTokens" .= cfg.outTokens
                , "loadReps" .= cfg.loadReps
                , "budgetMinutes" .= (cfg.budgetSecs / 60)
                , "coolToC" .= cfg.coolTo
                ]
            )
          , ( "load"
            , object
                [ "seconds" .= fmap r2 loadHeadline
                , "method" .= loadMethod
                , "fromMemory" .= sm' lm
                , "fromDisk" .= sm' ld
                , "serverStart" .= sm' ss
                , "withWarmup" .= sm' cb
                ]
            )
          , ("warmup", toJSON (sm' wu))
          , ("overheadSeconds", toJSON (sm' oh))
          , ("prefill", toJSON prefillRows)
          , ( "decode"
            , object
                [ "tokens" .= cfg.outTokens
                , "tokPerSec" .= fmap r2 shallowDecode
                , "byDepth" .= [object ["promptTokens" .= pt, "regime" .= reg, "tokPerSec" .= summaryJSON s] | (pt, reg, s) <- sortOn (\(pt, _, _) -> pt) byDepth]
                ]
            )
          , ("predict", object ["burst" .= fitsFor Burst, "sustained" .= fitsFor Sustained])
          , ( "reuse"
            , object
                [ "bundleTokens" .= listToMaybe (reverse sizesOk)
                , "ttft" .= sm' (ttftsOf reuseClean)
                , "coldTtft" .= fmap r2 coldAtBig
                , "coldRegime" .= fmap (\(_, reg, _, _) -> reg) bigRow
                , "speedup" .= (r2 <$> ((/) <$> coldAtBig <*> median (ttftsOf reuseClean)))
                , "trials" .= map trialJSON ru
                ]
            )
          , ("warmPrefillSeconds", toJSON (r2 <$> median (ttftsOf reuseClean)))
          , ("schema", toJSON schemaVerdict)
          , ("problems", toJSON problems)
          , ("observations", toJSON observations)
          , ("facts", Object (KeyMap.fromList [(Key.fromText k, v) | (k, v) <- facts]))
          , ("restraint", restraint)
          , ("conditions", conditions)
          , ("durationSeconds", toJSON (r2 (tEnd - tStart)))
          ]
      }
  where
    filterM' p = fmap catMaybes . mapM (\x -> (\ok -> if ok then Just x else Nothing) <$> p x)

-- | Whether a size has what it needs: minReps precise burst trials, or,
-- when it produced no burst trial at all, minReps precise sustained ones.
sizeDone :: Config -> [Judged] -> Bool
sizeDone cfg js =
  let b = [j | j <- js, regimeOf j == Burst]
      s = [j | j <- js, regimeOf j == Sustained]
      precise xs = maybe False (<= cfg.target) (relHalfWidth xs)
      enough xs =
        length xs >= cfg.minReps
          && precise (mapMaybe (.trial.ttft) xs)
          && (let rs = mapMaybe (decodeRate . (.trial)) xs in null rs || precise rs)
   in enough b || (null b && enough s)

-- | The trials a size's headline figure comes from, and their regime.
headline :: Config -> [Judged] -> (Text, [Judged])
headline cfg js
  | length b >= cfg.minReps = ("burst", b)
  | length s >= cfg.minReps = ("sustained", s)
  | not (null b) = ("burst", b)
  | not (null s) = ("sustained", s)
  | otherwise = ("contended", js)
  where
    b = [j | j <- js, regimeOf j == Burst]
    s = [j | j <- js, regimeOf j == Sustained]

trialJSON :: Judged -> Value
trialJSON j =
  object
    [ "promptTokens" .= j.trial.promptTokens
    , "ttft" .= fmap r2 j.trial.ttft
    , "decodeTokPerSec" .= fmap r2 (decodeRate j.trial)
    , "tokens" .= fromMaybe j.trial.pieces j.trial.completionTokens
    , "seconds" .= r2 j.trial.total
    , "regime" .= regimeName j.verdict.regime
    , "meanClock" .= fmap r2 j.verdict.meanClock
    , "maxTempC" .= fmap r2 j.verdict.maxTemp
    , "startTempC" .= fmap r2 j.startTemp
    , "waitedSeconds" .= r2 j.waited
    , "samples" .= j.verdict.sampleCount
    ]

-- | One timed request. Paced, it first waits for an idle machine under the
-- starting temperature; immediate, it does not, which is right only for
-- requests whose point is to follow another at once (warmup, steady state).
timed :: Config -> Target -> Bool -> Request -> IO (Either Text Judged)
timed cfg tg pace req = do
  (w, temp) <- case (pace, cfg.sampler) of
    (True, Just s) -> waitCool s cfg.coolTo cfg.coolTimeout
    _ -> pure (0, Nothing)
  r <- streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend tg.name req
  case r of
    Left e -> pure (Left e)
    Right t -> do
      -- A request shorter than the two-second sampling interval may hold no
      -- sample of its own; the one taken just before it describes it.
      ss <- case cfg.sampler of
        Nothing -> pure []
        Just s -> do
          inside <- samplesBetween s t.started t.ended
          if null inside then samplesBetween s (t.started - 4) t.ended else pure inside
      pure (Right (Judged t (judge ss) w temp))

sayTrial :: Int -> Judged -> IO ()
sayTrial s j =
  say
    ( T.pack
        ( printf
            "  %5d tokens: ttft %s s, decode %s tok/s, %s (clock %s, %s C, waited %.0f s)"
            (fromMaybe s j.trial.promptTokens)
            (maybe "-" (printf "%.2f") j.trial.ttft :: String)
            (maybe "-" (printf "%.2f") (decodeRate j.trial) :: String)
            (T.unpack (regimeName j.verdict.regime))
            (maybe "-" (printf "%.0f%%" . (* 100)) j.verdict.meanClock :: String)
            (maybe "-" (printf "%.0f") j.verdict.maxTemp :: String)
            j.waited
        )
    )

-- | Unload every model an ollama server holds, and wait until it holds
-- none, for at most a minute.
unloadAll :: Client -> Endpoint -> IO ()
unloadAll client ep = do
  let loaded = do
        r <- getBody client NoAuth (ep.url <> "/api/ps") 10
        pure case r of
          Right body | Just v <- Aeson.decode body, Just (Array ms) <- pathTo ["models"] v -> mapMaybe (textAt ["name"]) (foldr (:) [] ms)
          _ -> []
      wait n = do
        ms <- loaded
        unless (null ms || n <= (0 :: Int)) do
          forM_ ms \m -> postJsonWithin (Just 60) client NoAuth ep.url "/api/generate" (object ["model" .= m, "keep_alive" .= (0 :: Int)])
          threadDelay 1000000
          wait (n - 1)
  wait 60

waitHealthy :: Client -> Text -> Double -> IO Bool
waitHealthy client url limit = do
  t0 <- now
  let loop = do
        r <- getBody client NoAuth (url <> "/health") 5
        let ok = case r of
              Right body -> case Aeson.decode body >>= textAt ["status"] of
                Just s -> s == "ok"
                Nothing -> True
              Left _ -> False
        t <- now
        if ok then pure True else if t - t0 > limit then pure False else threadDelay 500000 >> loop
  loop

-- | A prompt of about n tokens that asks for a long answer, so one request
-- times both the reading and the writing. The nonce comes first, so no
-- prefix cache holds any of it.
filler :: Backend -> Int -> Text -> Text
filler b n nonce = fillerBody b n nonce <> "\n\nIgnore the code above. Count upward from one in English words, separated by spaces. Do not stop early."

fillerBody :: Backend -> Int -> Text -> Text
fillerBody b n nonce =
  let paragraph =
        "module Probe where\n\
        \-- | Sum a list strictly, left to right, starting from zero.\n\
        \total :: [Int] -> Int\n\
        \total = go 0\n\
        \  where\n\
        \    go acc [] = acc\n\
        \    go acc (x : xs) = let acc' = acc + x in acc' `seq` go acc' xs\n"
      bytes = floor (fromIntegral n * b.charsPerToken) :: Int
      body = T.take bytes (T.replicate (bytes `div` T.length paragraph + 1) paragraph)
   in "Probe " <> nonce <> ".\n" <> body

-- | What the server reports about the model itself.
factsOf :: Client -> Target -> IO [(Text, Value)]
factsOf client tg = case tg.backend.engine of
  Ollama -> do
    shown <- postJsonWithin (Just 30) client NoAuth tg.ep.url "/api/show" (object ["model" .= tg.name])
    tags <- getBody client NoAuth (tg.ep.url <> "/api/tags") 15
    let showV = either (const Nothing) Aeson.decode shown :: Maybe Value
        tagV = either (const Nothing) Aeson.decode tags :: Maybe Value
        sizeBytes = do
          Array ms <- tagV >>= pathTo ["models"]
          listToMaybe [n | m <- foldr (:) [] ms, textAt ["name"] m == Just tg.name, Just n <- [intAt ["size"] m]]
        paramCount = do
          Object mi <- showV >>= pathTo ["model_info"]
          Number n <- KeyMap.lookup "general.parameter_count" mi
          pure (round (toRealFloat n :: Double) :: Integer)
    pure $
      catMaybes
        [ ("parameterCount",) . toJSON <$> paramCount
        , ("parameterSize",) . String <$> (showV >>= textAt ["details", "parameter_size"])
        , ("quantization",) . String <$> (showV >>= textAt ["details", "quantization_level"])
        , ("family",) . String <$> (showV >>= textAt ["details", "family"])
        , ("format",) . String <$> (showV >>= textAt ["details", "format"])
        , ("sizeBytes",) . toJSON <$> sizeBytes
        ]
  LlamaServer -> do
    r <- getBody client NoAuth (tg.ep.url <> "/v1/models") 15
    let v = either (const Nothing) Aeson.decode r :: Maybe Value
        meta = do
          Array ds <- v >>= pathTo ["data"]
          d <- listToMaybe (foldr (:) [] ds)
          pathTo ["meta"] d
    pure $
      catMaybes
        [ ("parameterCount",) . toJSON <$> (meta >>= intAt ["n_params"])
        , ("sizeBytes",) . toJSON <$> (meta >>= intAt ["size"])
        , ("trainedContext",) . toJSON <$> (meta >>= intAt ["n_ctx_train"])
        , ("vocabulary",) . toJSON <$> (meta >>= intAt ["n_vocab"])
        ]
  HailoOllama -> pure []

-- | What the server says one request can hold: llama-server's n_ctx, the
-- model's trained context on ollama. hailo-ollama reports nothing, and its
-- window is 2,048 for every model in the zoo.
windowOf :: Client -> Target -> IO (Maybe Int)
windowOf client tg = case tg.backend.engine of
  LlamaServer -> do
    r <- getBody client NoAuth (tg.ep.url <> "/props") 15
    pure (either (const Nothing) (\body -> Aeson.decode body >>= intAt ["default_generation_settings", "n_ctx"]) r)
  Ollama -> do
    r <- postJsonWithin (Just 15) client NoAuth tg.ep.url "/api/show" (object ["model" .= tg.name])
    pure case r of
      Left _ -> Nothing
      Right body -> do
        v <- Aeson.decode body
        Object mi <- pathTo ["model_info"] v
        case [n | (k, Number n) <- KeyMap.toList mi, ".context_length" `T.isSuffixOf` Key.toText k] of
          (n : _) -> Just (round (toRealFloat n :: Double))
          [] -> Nothing
  HailoOllama -> pure (Just 2048)

pathTo :: [Text] -> Value -> Maybe Value
pathTo [] v = Just v
pathTo (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= pathTo ks
pathTo _ _ = Nothing

intAt :: [Text] -> Value -> Maybe Int
intAt p v = case pathTo p v of
  Just (Number n) -> Just (round (toRealFloat n :: Double))
  _ -> Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt p v = case pathTo p v of
  Just (String t) -> Just t
  _ -> Nothing

r2 :: Double -> Double
r2 x = fromIntegral (round (x * 100) :: Integer) / 100

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-bench: " <>)