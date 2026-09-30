-- | What the inference machine was doing while it was measured, and the
-- pacing that keeps its temperature from deciding the numbers.
--
-- Part of llmq-bench; Main's header says what is measured and why.
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
--
-- A timing is only comparable to another timing taken under the same
-- conditions. On oracle three things change them: other work on the same
-- four cores (the canary's builds did this on 2026-09-28), thermal
-- throttling, and memory pressure (a second resident model). A background
-- thread reads the row's Prometheus node exporter every two seconds for the
-- whole run, and every timed request is judged against the samples taken
-- while it ran.
--
-- ============================================================================
-- WHAT THE NIGHT OF 2026-09-29 SHOWED
-- ============================================================================
--
-- A bare Pi 5 running a 7B model on all four cores reaches 85 to 88 C
-- within minutes, and its firmware then moves the clock between 2.4 and
-- 1.5 GHz. Every round of the grid after the first ran 15 to 25% slower
-- than the first, which had started cool, and the first protocol flagged
-- none of it: it judged the clock by the median of the samples, which
-- stays at 2.4 GHz while fewer than half the samples catch the drop.
--
-- ============================================================================
-- WHAT IS DONE ABOUT IT
-- ============================================================================
--
--   The clock is judged by its mean over the trial, which is the fraction
--   of the trial the CPU spent at full speed, and so what the timing
--   depends on.
--
--   Every timed request waits first for an idle machine below a starting
--   temperature (`waitCool`). Every trial therefore starts from the same
--   state, so the first round is no longer a different experiment from
--   the rest.
--
--   A trial is then put in a regime by what it measured, not by guess:
--
--     burst      the mean clock stayed at or above 97% of maximum: what a
--                request to an idle machine gets
--     sustained  the clock fell below that: what a request gets once the
--                machine has been working long enough to throttle, which
--                on bare cooling a long prompt does by itself
--     contended  the median number of runnable tasks was more than the
--                core count plus two: someone else was using the machine,
--                and the trial describes nothing about the model
--
--   Pacing cannot stop a ten-minute all-core prefill from heating a bare
--   Pi 5 into throttling; only a cooler can. It makes every short request
--   a clean burst measurement, and it makes the long ones say that they
--   throttled and by how much, per trial, in the output.
--
-- Without a node exporter nothing can be judged, no pacing is possible,
-- the output says conditions were not observed, and every trial counts as
-- burst.
module Conditions
  ( Sample (..)
  , Sampler
  , startSampler
  , samplesBetween
  , observed
  , Regime (..)
  , regimeName
  , Verdict (..)
  , judge
  , waitQuiet
  , waitCool
  , now
  , summaryOf
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever, void)
import Data.Aeson (Value, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (sort)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Clock (getMonotonicTime)
import OpenSlop.Http (Auth (..), Client, HttpFailure, getBody)
import Text.Read (readMaybe)

data Sample = Sample
  { at :: Double
  , procsRunning :: Maybe Double
  , load1 :: Maybe Double
  , tempC :: Maybe Double
  , freqRatio :: Maybe Double
  , memAvailable :: Maybe Double
  , cores :: Maybe Int
  }

newtype Sampler = Sampler
  { store :: IORef [Sample]
  }

now :: IO Double
now = getMonotonicTime

-- | Start reading http://HOST:9100/metrics every two seconds.
startSampler :: Client -> Text -> IO Sampler
startSampler client host = do
  ref <- newIORef []
  let u = "http://" <> host <> ":9100/metrics"
  void $ forkIO $ forever do
    t <- now
    r <- try (getBody client NoAuth u 2) :: IO (Either SomeException (Either HttpFailure BL.ByteString))
    case r of
      Right (Right body) -> modifyIORef' ref (parse t (TE.decodeUtf8Lenient (BL.toStrict body)) :)
      _ -> pure ()
    threadDelay 2000000
  pure (Sampler ref)

samplesBetween :: Sampler -> Double -> Double -> IO [Sample]
samplesBetween s a b = filter (\x -> x.at >= a && x.at <= b) <$> readIORef s.store

-- | Whether any sample has ever arrived.
observed :: Sampler -> IO Bool
observed s = not . null <$> readIORef s.store

data Regime = Burst | Sustained | Contended
  deriving stock (Eq, Show)

regimeName :: Regime -> Text
regimeName = \case
  Burst -> "burst"
  Sustained -> "sustained"
  Contended -> "contended"

-- | One trial's conditions, from the samples taken while it ran.
data Verdict = Verdict
  { regime :: Regime
  , meanClock :: Maybe Double
  -- ^ mean CPU clock over maximum during the trial
  , maxTemp :: Maybe Double
  , sampleCount :: Int
  }

judge :: [Sample] -> Verdict
judge ss =
  let coreCount = case mapMaybe (.cores) ss of
        (c : _) -> c
        [] -> 4
      procs = med (mapMaybe (.procsRunning) ss)
      clock = avg (mapMaybe (.freqRatio) ss)
      temps = mapMaybe (.tempC) ss
      reg
        | maybe False (> fromIntegral coreCount + 2) procs = Contended
        | maybe False (< 0.97) clock = Sustained
        | otherwise = Burst
   in Verdict
        { regime = reg
        , meanClock = clock
        , maxTemp = if null temps then Nothing else Just (maximum temps)
        , sampleCount = length ss
        }

-- | Wait until the machine is idle and under the temperature: every sample
-- from the last eight seconds, at least two of them, shows at most two
-- runnable tasks and a temperature under it. Every sample rather than their
-- median, because the machine heats in seconds and a median over a longer
-- window reports the temperature it had before. Gives up after the
-- timeout. Returns the seconds waited, whether it got there, and the
-- latest temperature.
waitQuiet :: Sampler -> Double -> Double -> IO (Double, Bool, Maybe Double)
waitQuiet s maxTemp timeoutSecs = do
  t0 <- now
  let loop = do
        t <- now
        recent <- readIORef s.store
        let fresh = takeWhile (\x -> x.at >= t - 8) recent
            latestTemp = listToMaybe fresh >>= (.tempC)
            quiet =
              length fresh >= 2
                && all (maybe False (<= 2) . (.procsRunning)) fresh
                && all (maybe True (< maxTemp) . (.tempC)) fresh
        if quiet
          then pure (t - t0, True, latestTemp)
          else
            if t - t0 >= timeoutSecs
              then pure (t - t0, False, latestTemp)
              else threadDelay 2000000 >> loop
  loop

-- | Before one timed request: wait for an idle machine under the starting
-- temperature. When the machine already qualifies this returns at once, so
-- short requests in a row cost nothing while it stays cool. Returns the
-- seconds waited and the temperature at the start.
waitCool :: Sampler -> Double -> Double -> IO (Double, Maybe Double)
waitCool s startTemp timeoutSecs = do
  (w, _, temp) <- waitQuiet s startTemp timeoutSecs
  pure (w, temp)

-- | Everything observed between two instants, for the output.
summaryOf :: [Sample] -> Value
summaryOf ss =
  object
    [ "samples" .= length ss
    , "maxTempC" .= maxOf (mapMaybe (.tempC) ss)
    , "minFreqRatio" .= minOf (mapMaybe (.freqRatio) ss)
    , "meanFreqRatio" .= avg (mapMaybe (.freqRatio) ss)
    , "maxProcsRunning" .= maxOf (mapMaybe (.procsRunning) ss)
    , "maxLoad1" .= maxOf (mapMaybe (.load1) ss)
    , "minMemAvailableGiB" .= fmap (/ 1073741824) (minOf (mapMaybe (.memAvailable) ss))
    ]
  where
    maxOf xs = if null xs then Nothing else Just (maximum xs)
    minOf xs = if null xs then Nothing else Just (minimum xs)

med :: [Double] -> Maybe Double
med [] = Nothing
med xs = let s = sort xs in Just (s !! (length s `div` 2))

avg :: [Double] -> Maybe Double
avg [] = Nothing
avg xs = Just (sum xs / fromIntegral (length xs))

-- | The Prometheus text format, reduced to what the judgement needs.
parse :: Double -> Text -> Sample
parse t body =
  let rows = mapMaybe line (T.lines body)
      one k = case [v | (n, _, v) <- rows, n == k] of
        (v : _) -> Just v
        [] -> Nothing
      alls k = [v | (n, _, v) <- rows, n == k]
      cur = alls "node_cpu_scaling_frequency_hertz"
      mx = alls "node_cpu_scaling_frequency_max_hertz"
      temps = alls "node_thermal_zone_temp" <> alls "node_hwmon_temp_celsius"
   in Sample
        { at = t
        , procsRunning = one "node_procs_running"
        , load1 = one "node_load1"
        , tempC = if null temps then Nothing else Just (maximum temps)
        , freqRatio = if null cur || null mx then Nothing else Just (sum cur / fromIntegral (length cur) / maximum mx)
        , memAvailable = one "node_memory_MemAvailable_bytes"
        , cores = if null cur then Nothing else Just (length cur)
        }
  where
    line l
      | T.null l || T.isPrefixOf "#" l = Nothing
      | otherwise =
          let (key, rest) = T.breakOn " " l
              (name, labels) = T.breakOn "{" key
           in (name,labels,) <$> readMaybe (T.unpack (T.strip (T.takeWhile (/= ' ') (T.strip rest))))