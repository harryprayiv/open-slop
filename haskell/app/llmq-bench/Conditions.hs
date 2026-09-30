-- | What the inference machine was doing while it was measured.
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
-- throttling (a Pi 5 under hours of full load reaches its limit without a
-- good heatsink), and memory pressure (a second resident model). So a
-- background thread reads the row's Prometheus node exporter every two
-- seconds for the whole run, and every timed request is judged against the
-- samples taken while it ran.
--
-- ============================================================================
-- WHAT MAKES A TRIAL SUSPECT
-- ============================================================================
--
--   contended  the median number of runnable tasks during the trial was
--              more than the core count plus two. An inference server uses
--              about one thread per core, so more than that is someone else.
--   throttled  the median CPU clock during the trial was under 95% of the
--              clock's maximum.
--
-- Suspect trials are kept in the output but left out of the statistics
-- when enough clean trials remain; the protocol says how many were left
-- out and why. Without a node exporter nothing can be judged, the output
-- says conditions were not observed, and every trial counts.
module Conditions
  ( Sample (..)
  , Sampler
  , startSampler
  , samplesBetween
  , observed
  , Verdict (..)
  , judge
  , waitQuiet
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
import Data.Maybe (mapMaybe)
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

data Verdict = Verdict
  { contended :: Bool
  , throttled :: Bool
  }

-- | Judge one trial by the samples taken while it ran.
judge :: [Sample] -> Verdict
judge ss =
  let coreCount = case mapMaybe (.cores) ss of
        (c : _) -> c
        [] -> 4
      procs = med (mapMaybe (.procsRunning) ss)
      freq = med (mapMaybe (.freqRatio) ss)
   in Verdict
        { contended = maybe False (> fromIntegral coreCount + 2) procs
        , throttled = maybe False (< 0.95) freq
        }

-- | Wait until the machine is idle and cool: the median of the last five
-- samples has at most two runnable tasks and is under the temperature
-- given. Gives up after the timeout. Returns the seconds waited and whether
-- it became quiet.
waitQuiet :: Sampler -> Double -> Double -> IO (Double, Bool)
waitQuiet s maxTemp timeoutSecs = do
  t0 <- now
  let loop = do
        t <- now
        recent <- take 5 <$> readIORef s.store
        let fresh = [x | x <- recent, x.at >= t - 15]
            procs = med (mapMaybe (.procsRunning) fresh)
            temp = med (mapMaybe (.tempC) fresh)
            quiet = length fresh >= 3 && maybe False (<= 2) procs && maybe True (< maxTemp) temp
        if quiet
          then pure (t - t0, True)
          else
            if t - t0 >= timeoutSecs
              then pure (t - t0, False)
              else threadDelay 5000000 >> loop
  loop

-- | Everything observed between two instants, for the output.
summaryOf :: [Sample] -> Value
summaryOf ss =
  object
    [ "samples" .= length ss
    , "maxTempC" .= maxOf (mapMaybe (.tempC) ss)
    , "minFreqRatio" .= minOf (mapMaybe (.freqRatio) ss)
    , "medianFreqRatio" .= med (mapMaybe (.freqRatio) ss)
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
