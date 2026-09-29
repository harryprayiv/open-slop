-- | What oracle is doing right now: which models are in memory, whether
-- llama-server is up and busy, and the machine's load, memory and
-- temperature.
--
-- Part of llmq-models; Main describes the program.
--
-- ============================================================================
-- WHERE EACH FACT COMES FROM
-- ============================================================================
--
-- Nothing here needs anything installed on the client, and nothing needs
-- ssh. Every fact is one HTTP GET to a server that already answers:
--
--   in memory (ollama)   GET /api/ps on the cpu endpoint: each loaded
--                        model, its size, and when ollama will unload it
--   llama-server         GET /health (ok, loading, or no answer) and
--                        GET /slots (whether it is generating now)
--   NPU                  whether hailo-ollama answers at all
--   load, memory, temp   GET /metrics from Prometheus's node exporter on
--                        port 9100 of the same host, when the row runs one.
--                        Declared in the consumer's host configuration; a
--                        row without it shows "no telemetry" and nothing
--                        else changes.
--
-- The host for the node exporter is taken from the row's own endpoint URLs,
-- so no address is configured twice.
--
-- A fetch runs in the background every few seconds, with short timeouts,
-- so an unreachable row slows nothing down; the screen shows the last
-- answer and how old it is.
module Live
  ( Live (..)
  , Loaded (..)
  , emptyLive
  , fetchLive
  , endpointsOf
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), decode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.List (nub)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, getCurrentTime)
import OpenSlop.Http (Auth (..), Client, HttpFailure, getBody)
import Text.Read (readMaybe)

-- | A model resident in ollama's memory.
data Loaded = Loaded
  { name :: Text
  , sizeBytes :: Maybe Double
  , expiresAt :: Maybe Text
  }

data Live = Live
  { fetchedAt :: Maybe UTCTime
  , host :: Text
  , loaded :: [Loaded]
  , ollamaUp :: Bool
  , llamaHealth :: Text
  -- ^ "ok", "loading", "error", or "down"
  , llamaBusy :: Bool
  , hailoUp :: Bool
  , load1 :: Maybe Double
  , cores :: Maybe Int
  , memAvailable :: Maybe Double
  , memTotal :: Maybe Double
  , tempC :: Maybe Double
  , telemetry :: Bool
  }

emptyLive :: Live
emptyLive = Live Nothing "" [] False "down" False False Nothing Nothing Nothing Nothing Nothing False

-- | (backend, url) pairs from the catalogue document llmq reads.
endpointsOf :: Value -> [(Text, Text)]
endpointsOf doc = case at ["endpoints"] doc of
  Just (Array xs) ->
    [ (b, u)
    | Object o <- foldr (:) [] xs
    , Just (String b) <- [KeyMap.lookup "backend" o]
    , Just (String u) <- [KeyMap.lookup "url" o]
    ]
  _ -> []

fetchLive :: Client -> [(Text, Text)] -> IO Live
fetchLive client eps = do
  now <- getCurrentTime
  let urlFor b = lookup b eps
      hostOf u = T.takeWhile (/= ':') (fromMaybe u (T.stripPrefix "http://" u))
      hosts = nub (map (hostOf . snd) eps)
      theHost = fromMaybe "" (listToMaybe hosts)
  ps <- maybe (pure Nothing) (\u -> get (u <> "/api/ps")) (urlFor "cpu")
  health <- maybe (pure Nothing) (\u -> get (u <> "/health")) (urlFor "llamacpp")
  slots <- maybe (pure Nothing) (\u -> get (u <> "/slots")) (urlFor "llamacpp")
  hailo <- maybe (pure Nothing) (\u -> get (u <> "/hailo/v1/list")) (urlFor "hailo")
  metrics <- if T.null theHost then pure Nothing else get ("http://" <> theHost <> ":9100/metrics")
  let psV = ps >>= decode
      loadedModels = case psV >>= at ["models"] of
        Just (Array ms) ->
          [ Loaded n (num ["size"] m) (txt ["expires_at"] m)
          | m <- foldr (:) [] ms
          , Just n <- [txt ["name"] m]
          ]
        _ -> []
      healthState = case health of
        Nothing -> "down"
        Just b -> case decode b >>= txt ["status"] of
          Just s -> s
          Nothing -> "ok"
      busy = case slots >>= decode of
        Just (Array ss) -> or [True | Object s <- foldr (:) [] ss, Just (Bool True) <- [KeyMap.lookup "is_processing" s]]
        _ -> False
      samples = maybe [] (parseMetrics . TE.decodeUtf8Lenient . BL.toStrict) metrics
      metric n = listToMaybe [v | (k, _, v) <- samples, k == n]
      coreCount = case [lbls | (k, lbls, _) <- samples, k == "node_cpu_seconds_total", "mode=\"idle\"" `T.isInfixOf` lbls] of
        [] -> Nothing
        xs -> Just (length xs)
      temperature =
        listToMaybe ([v | (k, _, v) <- samples, k == "node_thermal_zone_temp"] <> [v | (k, _, v) <- samples, k == "node_hwmon_temp_celsius"])
  pure
    Live
      { fetchedAt = Just now
      , host = theHost
      , loaded = loadedModels
      , ollamaUp = ps /= Nothing
      , llamaHealth = healthState
      , llamaBusy = busy
      , hailoUp = hailo /= Nothing
      , load1 = metric "node_load1"
      , cores = coreCount
      , memAvailable = metric "node_memory_MemAvailable_bytes"
      , memTotal = metric "node_memory_MemTotal_bytes"
      , tempC = temperature
      , telemetry = metrics /= Nothing
      }
  where
    get u = do
      r <- try (getBody client NoAuth u 3) :: IO (Either SomeException (Either HttpFailure BL.ByteString))
      pure case r of
        Right (Right b) -> Just b
        _ -> Nothing

-- | Prometheus text format, one sample per line: name, labels, value.
-- Comment lines and anything unparseable are skipped.
parseMetrics :: Text -> [(Text, Text, Double)]
parseMetrics = mapMaybe line . T.lines
  where
    line l
      | T.null l || T.isPrefixOf "#" l = Nothing
      | otherwise =
          let (nameAndLabels, rest) = T.breakOnEnd " " (T.stripEnd l)
              key = T.stripEnd nameAndLabels
              (n, lbls) = T.breakOn "{" key
           in (T.strip n,lbls,) <$> readMaybe (T.unpack (T.strip rest))

at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= at ks
at _ _ = Nothing

num :: [Text] -> Value -> Maybe Double
num p v = case at p v of
  Just (Number n) -> Just (toRealFloat n)
  _ -> Nothing

txt :: [Text] -> Value -> Maybe Text
txt p v = case at p v of
  Just (String t) -> Just t
  _ -> Nothing
