-- | llmq-bench: measure every model the fleet serves, thoroughly enough
-- that the numbers can decide which model does which job.
--
-- ============================================================================
-- WHAT IT ANSWERS
-- ============================================================================
--
-- For each model: how long it takes to become usable (load, from the SD
-- card and from RAM, and the first-request warmup after it), how long
-- before the first word of an answer for a prompt of a given size, how fast
-- it writes once it has started and how that slows as the context fills,
-- what a cached prefix is worth, whether it honours a JSON Schema, and how
-- readily it refuses. Every timed figure is repeated until its 95%
-- confidence interval is within 5% of its mean or a repetition limit is
-- reached, and every figure carries its raw samples, so anyone can
-- recompute it. Protocol has the order of operations; Stats
-- has the statistics; Probe has how a request is timed; Conditions has how
-- the machine is watched while it is measured.
--
-- ============================================================================
-- HOW THIS COMPARES WITH HOW OTHERS MEASURE
-- ============================================================================
--
-- llama.cpp's llama-bench and MLPerf's inference rules time prefill and
-- generation separately, repeat each, and report a mean with its spread;
-- MLPerf additionally fixes and records the system state, and rejects a run
-- whose conditions moved. Most published local-model numbers are one run of
-- one prompt. This follows the first group: streamed requests so one
-- request yields both phases from the client's own clock, several prompt
-- sizes so the cost of a prompt is a fitted curve rather than one rate,
-- repetition to a precision target, a machine watched during every trial,
-- and trials taken under contention or throttling set aside.
--
-- What it does not do: it measures one request at a time. Throughput under
-- concurrent requests is a different experiment and a different number.
--
-- ============================================================================
-- WHERE THE RESULTS GO
-- ============================================================================
--
-- Into the measurements file in this machine's cache (OpenSlop.Measured:
-- $OPEN_SLOP_MEASURED, else $XDG_CACHE_HOME/open-slop/measured.json), which
-- every open-slop program lays over the catalogue it was built with. They
-- stay there until you delete the file or clear the cache. The file is
-- written after every model, so a run that stops part way keeps what it
-- finished, and the next run carries on from there.
--
--   llmq-bench                    measure what is new, changed, stale or
--                                 from an older protocol
--   llmq-bench --preflight        check everything an unattended run needs,
--                                 and say what it would measure
--   llmq-bench --pending          say what it would measure, and nothing else
--   llmq-bench --all              measure everything the servers list
--   llmq-bench --rejudge          recompute the refusal verdicts from the
--                                 stored answers, asking no model
--   llmq-bench --merge FILE       the same, against FILE instead of the cache
--   llmq-bench -o FILE            a fresh run of everything to FILE, or to
--                                 stdout with -o -, leaving the cache alone
--
-- It never starts on its own. llmq-models notices served models that need
-- measuring and says so; running this, overnight, is a person's decision.
--
-- ============================================================================
-- UNATTENDED: --control USER@HOST
-- ============================================================================
--
-- With it, one run covers everything (Control): llama-server is stopped for
-- the ollama and hailo models, so it holds no memory while they are timed,
-- then started for its own model, then left as it was found; the page cache
-- is dropped before alternate loads, so load from the SD card is measured
-- as well as load from RAM; and llama-server's start is timed as its load.
-- Without it, an endpoint that does not answer is skipped and keeps its
-- entries, and loads are from whatever the page cache holds.
--
-- ============================================================================
-- HEAT
-- ============================================================================
--
-- A bare Pi 5 throttles within minutes of all-core work (Conditions has
-- the night that showed it). Every timed request waits for an idle machine
-- under --cool-to degrees first, so every trial starts from the same
-- state, and every trial is labelled burst or sustained by the clock it
-- actually ran at. Pacing costs wall-clock time, several minutes per long
-- trial on bare cooling; with a cooler most waits end at once.
--
-- ============================================================================
-- THE NUMBERS FOR A DECISION
-- ============================================================================
--
-- An answer of m tokens to a prompt of k thousand tokens, on a model already
-- in memory, takes about
--
--   ttftSeconds(k) + (m - 1) / decodeTokPerSec(k)
--
-- from predict.burst for a request to an idle machine, or predict.sustained
-- for one that follows enough work to throttle it; from a cold prefix
-- cache, or with reuse.ttft in place of the first term when the prompt's
-- prefix was just sent. Add load.fromDisk or load.fromMemory and warmup
-- when the model is not resident. The top-level tokPerSec, the prefill
-- rows, warmPrefillSeconds and load.seconds keep the shape llmq and
-- llmq-models already read, as medians of each size's headline regime.
module Main (main) where

import Conditions (Sampler, observed, startSampler)
import Control
import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Exception (AsyncException (UserInterrupt), finally)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value (..), eitherDecodeFileStrict, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (nub, partition)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime, showGregorian, utctDay)
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Http
import OpenSlop.Measured
import Options.Applicative
import Protocol
import Restraint (rejudge)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)
import Text.Printf (printf)

data Opts = Opts
  { catalogueFile :: Maybe FilePath
  , out :: Maybe FilePath
  , mergeFile :: Maybe FilePath
  , only :: Maybe Text
  , timeoutSeconds :: Int
  , noProbes :: Bool
  , maxAgeDays :: Integer
  , benchAll :: Bool
  , pendingOnly :: Bool
  , rejudgeOnly :: Bool
  , preflight :: Bool
  , controlTarget :: Maybe Text
  , noDisk :: Bool
  , minReps :: Int
  , maxReps :: Int
  , precision :: Double
  , sizesArg :: Text
  , outTokens :: Int
  , loadReps :: Int
  , budgetMinutes :: Double
  , coolTo :: Double
  , coolTimeout :: Double
  , reprobe :: Bool
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> optional (strOption (long "catalogue" <> metavar "FILE" <> help "the built catalogue JSON (default $OPEN_SLOP_CATALOGUE)"))
    <*> optional (strOption (long "out" <> short 'o' <> metavar "FILE" <> help "a fresh run of everything to FILE, or stdout with -, leaving the measurements file alone"))
    <*> optional (strOption (long "merge" <> metavar "FILE" <> help "the measurements file to update (default $OPEN_SLOP_MEASURED, else the cache)"))
    <*> optional (strOption (long "only" <> metavar "SUBSTR" <> help "only models whose row/backend/name contains this"))
    <*> option auto (long "timeout" <> metavar "SECS" <> value 1800 <> showDefault <> help "ceiling for one request")
    <*> switch (long "no-probes" <> help "skip the restraint probes")
    <*> option auto (long "max-age" <> metavar "DAYS" <> value 30 <> showDefault <> help "measure an unchanged model again once its entry is this old")
    <*> switch (long "all" <> help "measure every served model, changed or not")
    <*> switch (long "pending" <> help "list what would be measured and why, and measure nothing")
    <*> switch (long "rejudge" <> help "recompute the refusal verdicts in the measurements file from its stored answers")
    <*> switch (long "preflight" <> help "check ssh, sudo, telemetry and every server an unattended run needs, list what it would measure, and measure nothing")
    <*> optional (strOption (long "control" <> metavar "USER@HOST" <> help "ssh destination allowed to switch llama-server and drop the page cache on the row"))
    <*> switch (long "no-disk" <> help "with --control: do not drop the page cache, so no load from the SD card is measured")
    <*> option auto (long "min-reps" <> metavar "N" <> value 3 <> showDefault <> help "repetitions of every timed figure before it may stop")
    <*> option auto (long "max-reps" <> metavar "N" <> value 6 <> showDefault <> help "repetitions of every timed figure at most")
    <*> option auto (long "precision" <> metavar "FRACTION" <> value 0.05 <> showDefault <> help "stop repeating once the 95% interval's half-width is within this fraction of the mean")
    <*> strOption (long "sizes" <> metavar "N,N,..." <> value "256,1024,2048,4096" <> showDefault <> help "prompt sizes in tokens; any the model's window cannot hold are left out")
    <*> option auto (long "out-tokens" <> metavar "N" <> value 64 <> showDefault <> help "tokens generated per grid request, which is what decode is timed over")
    <*> option auto (long "load-reps" <> metavar "N" <> value 3 <> showDefault <> help "loads per kind (from disk, from RAM)")
    <*> option auto (long "budget" <> metavar "MINUTES" <> value 60 <> showDefault <> help "per model; after min-reps, no repetition starts that would end past it")
    <*> option auto (long "cool-to" <> metavar "CELSIUS" <> value 65 <> showDefault <> help "every timed request waits for an idle machine under this temperature")
    <*> option auto (long "cool-timeout" <> metavar "SECS" <> value 900 <> showDefault <> help "longest wait for it before a request goes ahead anyway")
    <*> switch (long "reprobe" <> help "ask the restraint probes again even when the same weights answered them before")

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "measure the served models into this machine's measurements file"))
  -- systemctl stop sends SIGTERM, which by default ends the program without
  -- running any cleanup. As an exception in the main thread it runs the
  -- `finally` that puts llama-server back the way it was found.
  mainThread <- myThreadId
  _ <- installHandler sigTERM (Catch (throwTo mainThread UserInterrupt)) Nothing
  target <- maybe measuredPath pure o.mergeFile
  if o.rejudgeOnly
    then do
      old <- readMeasured target >>= either (die' . T.pack) pure
      writeAtomic target (rejudge old)
      say ("rejudged " <> T.pack target)
    else runBench o target

runBench :: Opts -> FilePath -> IO ()
runBench o target = do
  -- The built catalogue, not the overlaid one: whether a model is described
  -- decides whether its entry needs placeholder descriptions, and a
  -- placeholder that came from the measurements file describes nothing.
  path <- case o.catalogueFile of
    Just p -> pure p
    Nothing -> lookupEnv "OPEN_SLOP_CATALOGUE" >>= maybe (die' "no catalogue: pass --catalogue or set OPEN_SLOP_CATALOGUE") pure
  cat <- eitherDecodeFileStrict path >>= either (die' . T.pack) pure
  sizes <- either (die' . T.pack) pure (parseSizes o.sizesArg)
  client <- newClient
  today <- utctDay <$> getCurrentTime
  let day = T.pack (showGregorian today)
      fresh' = isJust o.out
      policy = Policy {maxAgeDays = o.maxAgeDays, wantProbes = not o.noProbes, everything = o.benchAll || fresh'}
      ctl = Control <$> o.controlTarget
      isLlama ep = maybe False (\b -> b.engine == LlamaServer) (Map.lookup ep.backend cat.backends)
      (llamaEps, otherEps) = partition isLlama cat.endpoints
      ordered = otherEps <> llamaEps
      hosts = nub (map (hostOf . (.url)) cat.endpoints)
  prior <- if fresh' then pure emptyMeasured else readMeasured target >>= either (die' . T.pack) pure
  unless fresh' (say ("measurements file: " <> T.pack target))

  samplers <- if o.pendingOnly then pure Map.empty else Map.fromList <$> forM hosts \h -> (h,) <$> startSampler client h
  let samplerFor ep = Map.lookup (hostOf ep.url) samplers
      cfg s =
        Config
          { minReps = o.minReps
          , maxReps = max o.minReps o.maxReps
          , target = o.precision
          , sizes = sizes
          , outTokens = o.outTokens
          , loadReps = o.loadReps
          , budgetSecs = o.budgetMinutes * 60
          , probes = not o.noProbes
          , timeoutSecs = o.timeoutSeconds
          , control = ctl
          , fromDisk = not o.noDisk
          , coolTo = o.coolTo
          , coolTimeout = o.coolTimeout
          , sampler = s
          , client = client
          }

  when o.preflight do
    ok <- runPreflight o client cat ctl samplers llamaEps
    unless ok exitFailure

  -- llama-server's state before the run, restored after it.
  llamaWasUp <- case ctl of
    Just c | not (null llamaEps), not o.pendingOnly -> Just <$> isActive c "llama-server.service"
    _ -> pure Nothing
  current <- newIORef prior
  freshAll <- newIORef []
  listedAll <- newIORef Map.empty
  let restore = case (ctl, llamaWasUp) of
        (Just c, Just up) -> do
          r <- llamaServer c (if up then "start" else "stop")
          say ("llama-server left " <> (if up then "running" else "stopped") <> " as it was found" <> either (": FAILED " <>) (const "") r)
        _ -> pure ()
      stopLlama = case (ctl, llamaWasUp) of
        (Just c, Just _) -> llamaServer c "stop" >>= either (\e -> say ("could not stop llama-server: " <> e)) (const (say "llama-server stopped for the other backends"))
        _ -> pure ()
      startLlama ep = case ctl of
        Just c | not o.pendingOnly -> do
          -- Nothing else may hold memory while llama-server is measured.
          forM_ [e | e <- otherEps, hostOf e.url == hostOf ep.url, maybe False (\b -> b.engine == Ollama) (Map.lookup e.backend cat.backends)] (unloadAll client)
          r <- llamaServer c "start"
          case r of
            Left e -> say ("could not start llama-server: " <> e)
            Right () -> do
              say "llama-server started for its own measurement; waiting for /health"
              waitUp client ep.url 600
        _ -> pure ()

  stopLlama
  ( forM_ ordered \ep -> do
      when (isLlama ep) (startLlama ep)
      case Map.lookup ep.backend cat.backends of
        Nothing -> say ("skip " <> endpointId ep <> ": no backend " <> ep.backend <> " in the catalogue")
        Just b -> do
          listing <- getBody client NoAuth (ep.url <> TE.decodeUtf8 (tagsPath b.engine)) 15
          case listing of
            Left f -> say ("skip " <> endpointId ep <> ": " <> describeFailure f <> "; its entries are kept")
            Right body -> case parseTags b.engine body of
              Nothing -> say ("skip " <> endpointId ep <> ": unreadable model listing; its entries are kept")
              Just served -> do
                modifyIORef' listedAll (Map.insertWith (<>) ep.backend [catalogueKey m.name | m <- served])
                let names = [m.name | m <- served]
                    wanted = [n | n <- names, maybe True (`T.isInfixOf` (endpointId ep <> "/" <> n)) o.only]
                forM_ wanted \name -> do
                  cur <- readIORef current
                  let fp = fingerprintOf body name
                      before = pathOf ["models", ep.backend, catalogueKey name] cur
                  case decide policy today fp before of
                    Keep why -> say ("keep " <> endpointId ep <> "/" <> name <> ": " <> why)
                    Measure why
                      | o.pendingOnly || o.preflight -> TIO.putStrLn (endpointId ep <> "/" <> name <> "  " <> why)
                      | otherwise -> do
                          say ("bench " <> endpointId ep <> "/" <> name <> ": " <> why)
                          let known = lookupModel cat ep.backend name
                              numCtx = case b.engine of
                                Ollama -> Just (fromMaybe b.ctx (known >>= (.ctx)))
                                _ -> Nothing
                              prior' = do
                                e <- before
                                Object r <- pathOf ["measured", "restraint"] e
                                day' <- case pathOf ["measured", "on"] e of
                                  Just (String d) -> Just d
                                  _ -> Nothing
                                recorded <- case pathOf ["measured", "fingerprint"] e of
                                  Just (String f) -> Just f
                                  _ -> Nothing
                                -- An empty answer means the probe was never really
                                -- answered (a think block counted as nothing before
                                -- protocol 3), so it is asked again.
                                let answered = case KeyMap.lookup "probes" r of
                                      Just (Array ps) -> not (null ps) && and [maybe False (not . T.null . T.strip) (textOf "answer" p) | p <- foldr (:) [] ps]
                                      _ -> False
                                if o.reprobe || Just recorded /= fp || not answered then Nothing else Just (Object r, day')
                          r <- measureModel (cfg (samplerFor ep)) (Target ep b name numCtx (filter (/= name) names) prior')
                          let entry = entryFor day ep b known name fp r
                          modifyIORef' freshAll (<> [(ep.backend, catalogueKey name, entry)])
                          unless fresh' do
                            modifyIORef' current (\c -> mergeInto c Map.empty [(ep.backend, catalogueKey name, entry)])
                            readIORef current >>= writeAtomic target
                            say ("  saved to " <> T.pack target)
    )
    `finally` restore

  fresh <- readIORef freshAll
  listed <- readIORef listedAll
  case o.out of
    _ | o.pendingOnly || o.preflight -> pure ()
    Just "-" -> BL.putStr (encode (mergeInto emptyMeasured Map.empty fresh)) >> putStrLn ""
    Just f -> writeAtomic f (mergeInto emptyMeasured Map.empty fresh) >> say ("wrote " <> T.pack f)
    Nothing -> do
      cur <- readIORef current
      let final = mergeInto cur listed []
      if final == prior
        then say ("nothing changed; " <> T.pack target <> " left as it was")
        else writeAtomic target final >> say ("wrote " <> T.pack target)

-- | Everything an unattended run depends on, checked now rather than
-- discovered at three in the morning.
runPreflight :: Opts -> Client -> Catalogue -> Maybe Control -> Map.Map Text Sampler -> [Endpoint] -> IO Bool
runPreflight o client cat ctl samplers llamaEps = do
  results <- newIORef []
  let check name act = do
        r <- act
        TIO.putStrLn ((if either (const False) (const True) r then "ok    " else "FAIL  ") <> name <> either (": " <>) (\d -> if T.null d then "" else ": " <> d) r)
        modifyIORef' results (r :)
  forM_ cat.endpoints \ep -> check ("server " <> endpointId ep) do
    case Map.lookup ep.backend cat.backends of
      Nothing -> pure (Left "no such backend in the catalogue")
      Just b -> do
        r <- getBody client NoAuth (ep.url <> TE.decodeUtf8 (tagsPath b.engine)) 10
        pure case r of
          Right body -> Right (maybe "unreadable listing" (\ms -> T.pack (show (length ms)) <> " models") (parseTags b.engine body))
          Left f
            | b.engine == LlamaServer && isJust ctl -> Right "not running now; the run starts it"
            | otherwise -> Left (describeFailure f)
  threadDelay 5000000
  forM_ (Map.toList samplers) \(h, s) -> check ("telemetry " <> h <> ":9100") do
    seen <- observed s
    pure (if seen then Right "" else Left "no node exporter answer; trials cannot be checked for contention or throttling")
  case ctl of
    Nothing -> TIO.putStrLn "--    no --control: llama-server is not switched, loads are not measured from disk, llama-server's start is not timed"
    Just c -> do
      check ("ssh " <> c.target) (remote c ["true"])
      unless o.noDisk $ check "sudo -n sysctl -w vm.drop_caches=3" (fmap (const "the page cache can be dropped") <$> dropCaches c)
      unless (null llamaEps) $ check "llama-server start, health and stop" do
        up <- isActive c "llama-server.service"
        r1 <- llamaServer c "start"
        healthy <- case (r1, llamaEps) of
          (Right (), ep : _) -> waitUp client ep.url 300 >> either (const False) (const True) <$> getBody client NoAuth (ep.url <> "/health") 5
          _ -> pure False
        r2 <- llamaServer c (if up then "start" else "stop")
        pure case (r1, healthy, r2) of
          (Left e, _, _) -> Left e
          (_, False, _) -> Left "started but /health did not answer within 300 s"
          (_, _, Left e) -> Left e
          _ -> Right ("restored to " <> if up then "running" else "stopped")
  rs <- readIORef results
  TIO.putStrLn ""
  TIO.putStrLn ("Models that would be measured, at most " <> T.pack (printf "%.0f" o.budgetMinutes) <> " minutes each plus loads and probes:")
  pure (all (either (const False) (const True)) rs)

waitUp :: Client -> Text -> Int -> IO ()
waitUp client url limit = loop limit
  where
    loop n = do
      r <- getBody client NoAuth (url <> "/health") 5
      case r of
        Right _ -> pure ()
        Left _ | n > 0 -> threadDelay 2000000 >> loop (n - 2)
        Left _ -> say ("llama-server did not answer /health within " <> T.pack (show limit) <> " s")

parseSizes :: Text -> Either String [Int]
parseSizes t = case mapM (\s -> case reads (T.unpack (T.strip s)) of [(n, "")] | n > 0 -> Just n; _ -> Nothing) (T.splitOn "," t) of
  Just ns | not (null ns) -> Right ns
  _ -> Left ("--sizes wants positive integers separated by commas, not " <> T.unpack t)

hostOf :: Text -> Text
hostOf u = T.takeWhile (/= ':') (fromMaybe u (T.stripPrefix "http://" u))

-- | The catalogue entry for one measured model.
entryFor :: Text -> Endpoint -> Backend -> Maybe Model -> Text -> Maybe Text -> Result -> Value
entryFor day ep b known name fp r =
  Object (KeyMap.fromList (measuredFields <> descriptive))
  where
    measuredFields =
      [ ("tokPerSec", maybe Null (Number . realToFrac) r.tokPerSec)
      , ( "measured"
        , Object
            ( KeyMap.fromList
                ( [ ("on", String day)
                  , ("fingerprint", maybe Null String fp)
                  , ("endpoint", String (endpointId ep))
                  , ("engine", String (engineName b.engine))
                  ]
                    <> r.measured
                )
            )
        )
      ]
    descriptive = case known of
      Just _ -> []
      Nothing ->
        [ ("summary", String ("measured " <> day <> ", not yet described: " <> rateLine))
        , ("docFit", String "unknown")
        , ("licence", String "unknown: not recorded; check the model card before relying on it")
        , ( "blurb"
          , String
              ( name
                  <> " on "
                  <> endpointId ep
                  <> ". Added by llmq-bench on "
                  <> day
                  <> " from measurement alone; nobody has described what it is good or bad at. "
                  <> rateLine
                  <> "."
              )
          )
        ]
    rateLine = maybe "decode not measured" (T.pack . printf "decode %.2f tok/s (median)") r.tokPerSec

textOf :: Text -> Value -> Maybe Text
textOf k (Object obj) = case KeyMap.lookup (Key.fromText k) obj of
  Just (String t) -> Just t
  _ -> Nothing
textOf _ _ = Nothing

pathOf :: [Text] -> Value -> Maybe Value
pathOf [] v = Just v
pathOf (k : ks) (Object obj) = KeyMap.lookup (Key.fromText k) obj >>= pathOf ks
pathOf _ _ = Nothing

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-bench: " <>)

die' :: Text -> IO a
die' t = hPutStrLn stderr ("llmq-bench: " <> T.unpack t) >> exitFailure