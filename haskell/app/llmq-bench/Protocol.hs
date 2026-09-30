-- | The measurement protocol for one model.
--
-- Part of llmq-bench; Main's header says what the figures mean and how they
-- are meant to be used. This module is the order of operations.
--
-- ============================================================================
-- THE ORDER
-- ============================================================================
--
--   1. Wait for a quiet, cool machine (Conditions.waitQuiet).
--   2. Facts and window from the server.
--   3. Load and warmup, loadReps times. On ollama every other model is
--      unloaded first, then this one, and each repetition times the load
--      alone (an empty /api/generate), then one short request, then two
--      more. With --control, repetitions alternate between a load with the
--      page cache dropped (from the SD card) and one without (from RAM).
--      On llama-server with --control the load is a restart timed to a
--      healthy /health. On hailo-ollama a load is switching to this model
--      from another, which cannot be separated from its first request.
--   4. The grid: a prompt of each size, answered with outTokens tokens,
--      streamed. Sizes are visited round-robin, one repetition of each per
--      round, so slow drift in the machine spreads over every size rather
--      than landing on one. Each prompt starts with a new nonce, so no
--      prefix cache can serve it. A size stops once both its ttft and its
--      decode rate have a 95% interval within `target` of the mean, after
--      at least minReps; everything stops at maxReps or the time budget.
--   5. Reuse: the largest prompt sent once to fill the cache, then again
--      with a different short question on the end each time. This is the
--      pattern of many questions over one bundle, and its ttft against the
--      cold ttft at the same size is what the cache is worth.
--   6. Schema: whether a JSON Schema request comes back in the schema.
--   7. Restraint: the eight probes, once each; temperature 0 makes them
--      deterministic, so repeating them adds nothing.
--
-- ============================================================================
-- WHAT COMES OUT, FOR DECISIONS
-- ============================================================================
--
--   predict.ttft     ttft = a + b*k + c*k^2 with k the prompt in thousands of
--                    tokens, fitted over every clean grid trial. The time to
--                    the first word of an answer to a prompt of any size in
--                    the measured range.
--   predict.decode   decode rate = d0 + d1*k: how generation slows as the
--                    context fills.
--   A whole answer of m tokens to a k-thousand-token prompt then takes about
--   ttft(k) + (m - 1) / decode(k), from a cold cache. With the prompt's
--   prefix cached, use reuse.ttft in place of ttft(k).
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
  }

data Result = Result
  { tokPerSec :: Maybe Double
  , measured :: [(Key.Key, Value)]
  }

-- | A trial with what the machine was doing while it ran.
data Judged = Judged
  { trial :: Trial
  , suspect :: [Text]
  }

measureModel :: Config -> Target -> IO Result
measureModel cfg tg = do
  tStart <- now
  problemsRef <- newIORef []
  let problem t = say ("  PROBLEM " <> t) >> modifyIORef' problemsRef (<> [t])
      eng = tg.backend.engine

  -- 1. quiet
  (waited, quiet) <- case cfg.sampler of
    Nothing -> threadDelay 30000000 >> pure (30, False)
    Just s -> waitQuiet s 65 900
  say (T.pack (printf "  waited %.0f s for a quiet machine%s" waited (if quiet then "" else " and gave up" :: String)))

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
      judged req = timedJudged cfg tg req

  -- 3. load and warmup
  loadMem <- newIORef []
  loadDisk <- newIORef []
  serverStart <- newIORef []
  combined <- newIORef []
  warmups <- newIORef []
  overheads <- newIORef []
  let firstAndSteady afterLoad = do
        f <- judged short
        s1 <- judged short
        s2 <- judged short
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
        t0 <- now
        llamaServer c "restart" >>= \case
          Left e -> problem ("llama-server restart failed: " <> e)
          Right () -> do
            ok <- waitHealthy cfg.client tg.ep.url 600
            t1 <- now
            if ok
              then modifyIORef' serverStart (<> [t1 - t0]) >> firstAndSteady True >> pure ()
              else problem "llama-server did not become healthy within 600 s of a restart"
      Nothing -> forM_ [1 .. cfg.loadReps] \_ -> firstAndSteady False
    HailoOllama -> forM_ [1 .. cfg.loadReps] \_ -> do
      case tg.others of
        (o : _) -> do
          _ <- streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend o short
          r <- firstAndSteady True
          forM_ r \(first, steady) -> forM_ steady \m -> modifyIORef' combined (<> [first - m])
        [] -> () <$ firstAndSteady False

  -- 4. the grid
  tGrid <- now
  let deadline = tStart + cfg.budgetSecs
  grid <- newIORef (Map.fromList [(s, []) | s <- sizesOk])
  counter <- newIORef (0 :: Int)
  -- Converged counts clean trials only, so a size with suspect trials
  -- keeps being repeated until it has minReps clean ones or runs out of
  -- repetitions; only the final figures fall back to suspect trials.
  let converged s = do
        ts <- Map.findWithDefault [] s <$> readIORef grid
        let clean = [j | j <- ts, null j.suspect]
            ttfts = mapMaybe (.trial.ttft) clean
            rates = mapMaybe (decodeRate . (.trial)) clean
            ok xs = maybe False (<= cfg.target) (relHalfWidth xs)
        pure (length clean >= cfg.minReps && ok ttfts && (null rates || ok rates))
      round' rep = do
        pending <- filterM' (fmap not . converged) sizesOk
        forM_ pending \s -> do
          ts <- Map.findWithDefault [] s <$> readIORef grid
          t <- now
          let expected = fromMaybe 0 (median (map (.trial.total) ts))
          if rep > cfg.minReps && t + expected > deadline
            then pure ()
            else do
              k <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
              r <- judged (Request (filler tg.backend s ("grid " <> T.pack (show k) <> " " <> T.pack (show t))) cfg.outTokens False tg.numCtx)
              case r of
                Left e -> problem (T.pack (show s) <> "-token prompt: " <> e)
                Right j -> do
                  forM_ j.trial.promptTokens \pt ->
                    when (fromIntegral pt < 0.8 * (fromIntegral s :: Double)) $
                      problem (T.pack (printf "%d-token prompt: the server read only %d tokens of it" s pt))
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
  reuseTtfts <- newIORef []
  case reverse sizesOk of
    [] -> pure ()
    (big : _) -> do
      bundleNonce <- now
      let bundle = fillerBody tg.backend big ("bundle " <> T.pack (show bundleNonce))
          ask i = judged (Request (bundle <> "\n\nQuestion " <> T.pack (show (i :: Int)) <> ": reply with the word ok.") 1 False tg.numCtx)
      _ <- ask 0
      let loop i
            | i > cfg.maxReps = pure ()
            | otherwise = do
                xs <- readIORef reuseTtfts
                t <- now
                let done' = i > cfg.minReps && (maybe False (<= cfg.target) (relHalfWidth xs) || t >= deadline + 600)
                unless done' do
                  ask i >>= \case
                    Left e -> problem ("reuse: " <> e)
                    Right j -> forM_ j.trial.ttft \v -> modifyIORef' reuseTtfts (<> [v])
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
  probeResults <-
    if not cfg.probes
      then pure []
      else forM restraintProbes \(probeName, prompt) ->
        streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend tg.name (Request prompt 120 False tg.numCtx) <&&> \case
          Left e -> (probeName, False, 0, "no answer: " <> T.take 120 e)
          Right t -> (probeName, refuses probeName t.text, t.total, T.take 300 (T.strip t.text))

  tEnd <- now
  everything <- maybe (pure []) (\s -> samplesBetween s tStart tEnd) cfg.sampler
  seen <- maybe (pure False) observed cfg.sampler
  problems <- readIORef problemsRef
  lm <- readIORef loadMem
  ld <- readIORef loadDisk
  ss <- readIORef serverStart
  cb <- readIORef combined
  wu <- readIORef warmups
  oh <- readIORef overheads
  ru <- readIORef reuseTtfts

  let overheadMed = fromMaybe 0 (median oh)
      perSize =
        [ (s, clean, length js - length clean)
        | (s, js) <- Map.toList gridDone
        , let clean = usable cfg js
        ]
      promptTokOf s clean = case mapMaybe (.trial.promptTokens) clean of
        [] -> (s, True)
        xs -> (round (fromMaybe (fromIntegral s) (median (map fromIntegral xs)) :: Double), False)
      prefillRows =
        [ object
            [ "promptTokens" .= pt
            , "tokensEstimated" .= est
            , "seconds" .= r2 m
            , "tokPerSec" .= r2 (fromIntegral pt / max 0.01 (m - overheadMed))
            , "ttft" .= summaryJSON sm
            , "excludedTrials" .= excluded
            ]
        | (s, clean, excluded) <- perSize
        , Just sm <- [summarise (mapMaybe (.trial.ttft) clean)]
        , let m = sm.median'
        , let (pt, est) = promptTokOf s clean
        ]
      byDepth =
        [ (pt, sm)
        | (s, clean, _) <- perSize
        , Just sm <- [summarise (mapMaybe (decodeRate . (.trial)) clean)]
        , let (pt, _) = promptTokOf s clean
        ]
      shallowDecode = (.median') . snd <$> listToMaybe (sortOn fst byDepth)
      ttftPoints =
        [ (fromIntegral (fromMaybe s j.trial.promptTokens) / 1000, t)
        | (s, clean, _) <- perSize
        , j <- clean
        , Just t <- [j.trial.ttft]
        ]
      decodePoints =
        [ (fromIntegral (fromMaybe s j.trial.promptTokens) / 1000, r)
        | (s, clean, _) <- perSize
        , j <- clean
        , Just r <- [decodeRate j.trial]
        ]
      ttftFit = case fitPoly 2 ttftPoints of
        Just f | length ttftPoints >= 4 -> Just ("a + b*k + c*k^2, k = prompt tokens / 1000" :: Text, f)
        _ -> ("a + b*k, k = prompt tokens / 1000",) <$> fitPoly 1 ttftPoints
      decodeFit = ("d0 + d1*k, k = prompt tokens / 1000" :: Text,) <$> fitPoly 1 decodePoints
      coldAtBig = case reverse perSize of
        ((_, clean, _) : _) -> median (mapMaybe (.trial.ttft) clean)
        [] -> Nothing
      suspects = sum [ex | (_, _, ex) <- perSize]
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
      conditions =
        object
          [ "observed" .= seen
          , "waitedForQuietSeconds" .= r2 waited
          , "quietAtStart" .= quiet
          , "suspectTrialsExcluded" .= suspects
          , "whole" .= summaryOf everything
          ]
      sm' = fmap summaryJSON . summarise
  say
    ( T.pack
        ( printf
            "  decode %s tok/s, load %s s, %d grid trials, %d set aside as suspect, %.0f min"
            (maybe "-" (printf "%.2f") shallowDecode :: String)
            (maybe "-" (printf "%.1f") loadHeadline :: String)
            (sum [length js | js <- Map.elems gridDone])
            suspects
            ((tEnd - tStart) / 60)
        )
    )
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
                , "byDepth" .= [object ["promptTokens" .= pt, "tokPerSec" .= summaryJSON s] | (pt, s) <- sortOn fst byDepth]
                ]
            )
          , ( "predict"
            , object
                [ "ttftSeconds" .= fmap (\(form, f) -> object ["form" .= form, "fit" .= fitJSON f]) ttftFit
                , "decodeTokPerSec" .= fmap (\(form, f) -> object ["form" .= form, "fit" .= fitJSON f]) decodeFit
                ]
            )
          , ( "reuse"
            , object
                [ "bundleTokens" .= listToMaybe (reverse sizesOk)
                , "ttft" .= sm' ru
                , "coldTtft" .= fmap r2 coldAtBig
                , "speedup" .= (r2 <$> ((/) <$> coldAtBig <*> median ru))
                ]
            )
          , ("warmPrefillSeconds", toJSON (r2 <$> median ru))
          , ("schema", toJSON schemaVerdict)
          , ("problems", toJSON problems)
          , ("facts", Object (KeyMap.fromList [(Key.fromText k, v) | (k, v) <- facts]))
          , ( "restraint"
            , if null probeResults
                then Null
                else
                  object
                    [ "asked" .= length probeResults
                    , "refused" .= length [() | (_, True, _, _) <- probeResults]
                    , "refusedWhich" .= [p | (p, True, _, _) <- probeResults]
                    , "probes" .= [object ["probe" .= p, "refused" .= r, "seconds" .= r2 secs, "answer" .= a] | (p, r, secs, a) <- probeResults]
                    ]
            )
          , ("conditions", conditions)
          , ("durationSeconds", toJSON (r2 (tEnd - tStart)))
          ]
      }
  where
    (<&&>) = flip fmap
    filterM' p = fmap catMaybes . mapM (\x -> (\ok -> if ok then Just x else Nothing) <$> p x)

-- | The clean trials, when there are at least minReps of them; otherwise
-- all of them. The output records how many were suspect, so a figure built
-- from them is marked as such.
usable :: Config -> [Judged] -> [Judged]
usable cfg js =
  let clean = [j | j <- js, null j.suspect]
   in if length clean >= cfg.minReps then clean else js

timedJudged :: Config -> Target -> Request -> IO (Either Text Judged)
timedJudged cfg tg req = do
  r <- streamAsk cfg.client cfg.timeoutSecs tg.ep tg.backend tg.name req
  case r of
    Left e -> pure (Left e)
    Right t -> do
      ss <- maybe (pure []) (\s -> samplesBetween s t.started t.ended) cfg.sampler
      let v = judge ss
          why = ["contended" | v.contended] <> ["throttled" | v.throttled]
      pure (Right (Judged t why))

sayTrial :: Int -> Judged -> IO ()
sayTrial s j =
  say
    ( T.pack
        ( printf
            "  %5d tokens: ttft %s s, decode %s tok/s%s"
            (fromMaybe s j.trial.promptTokens)
            (maybe "-" (printf "%.2f") j.trial.ttft :: String)
            (maybe "-" (printf "%.2f") (decodeRate j.trial) :: String)
            (if null j.suspect then "" else "  SUSPECT: " <> T.unpack (T.intercalate ", " j.suspect))
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
