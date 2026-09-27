-- | llmq-bench: measure every model every endpoint serves, and write the
-- result as catalogue data.
--
-- ============================================================================
-- WHY THIS EXISTS
-- ============================================================================
--
-- Adding a model used to mean hand-writing a catalogue entry, and the
-- numbers in it were whatever someone measured once, on whatever prompt
-- they had. This runs the same fixed probes against every served model and
-- emits JSON shaped for services.open-slop.catalogue.extra, so a new model
-- is described by measuring it rather than by editing open-slop.
--
-- Which models a machine runs is the consumer's business, not open-slop's.
-- The output belongs in the consumer's repository, committed beside the
-- host that serves the models, and imported as catalogue.extra there.
--
-- It needs no configuration: the endpoints come from the catalogue llmq
-- already reads ($OPEN_SLOP_CATALOGUE, which Nix writes with the consumer's
-- endpoints in it), and the models come from each server's own listing.
--
-- ============================================================================
-- WHAT IS MEASURED, AND HOW
-- ============================================================================
--
-- Everything is timed by the client's wall clock. Server-reported durations
-- are not used: on 2026-09-26 ollama reported 711 s of prefill inside a
-- 258 s wall clock.
--
-- Every request is deterministic: temperature 0, seed 1.
--
--   window     what the server says one request can hold: llama-server's
--              n_ctx from /props, the model's trained context from ollama's
--              /api/show. hailo-ollama reports nothing.
--   prefill    a prompt of about 1,000 tokens, and 4,000 where the window
--              allows, with one output token, so the wall clock is almost
--              all prompt evaluation. Each starts with a fresh nonce so no
--              server can answer it from a prefix cache.
--   warm       the 4,000-token prompt sent again verbatim. The ratio to the
--              cold figure is the prefix cache, which is what decides
--              whether many small requests over one bundle are affordable.
--   decode     128 output tokens from a short prompt. Includes a few tokens
--              of prefill, which at this size is noise.
--   schema     a request with a JSON Schema response_format, and whether the
--              answer came back as the schema says. hailo-ollama answers a
--              format field with HTTP 500, so it is not asked.
--
-- ============================================================================
-- WHAT THE OUTPUT CONTAINS
-- ============================================================================
--
-- For a model the catalogue already describes: tokPerSec and a `measured`
-- block only. Nix merges catalogue.extra with recursiveUpdate, so the
-- hand-written summary, licence and blurb survive and only the numbers
-- change.
--
-- For a model the catalogue does not describe: a complete entry, because
-- the Haskell decoder requires every descriptive field. docFit and licence
-- are "unknown", and the summary and blurb say what was measured and that
-- a person has not described it yet. That is a stated absence, and the
-- warning catalogue-check prints for an undescribed model goes away because
-- the model is now in the catalogue with honest placeholders.
--
-- Nothing here judges quality. Rate, window, cache and schema support are
-- measurable; whether a model writes good Haskell is a golden-set question.
module Main (main) where

import Control.Monad (forM, forM_, when)
import Data.Aeson (Value (..), eitherDecodeFileStrict, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Http
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import Text.Printf (printf)

data Opts = Opts
  { catalogueFile :: Maybe FilePath
  , out :: Maybe FilePath
  , only :: Maybe Text
  , timeoutSeconds :: Int
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> optional (strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON (default $OPEN_SLOP_CATALOGUE)"))
    <*> optional (strOption (long "out" <> short 'o' <> metavar "FILE" <> help "write the catalogue.extra JSON here (default stdout)"))
    <*> optional (strOption (long "only" <> metavar "SUBSTR" <> help "bench only models whose row/backend/name contains this"))
    <*> option auto (long "timeout" <> metavar "SECS" <> value 1800 <> showDefault <> help "per request; a cold 4,000-token prefill on a 7B takes minutes")

-- | One model's results.
data Measured = Measured
  { window :: Maybe Int
  , prefill :: [(Int, Bool, Double)]
  -- ^ (prompt tokens, whether that count is estimated, seconds)
  , warm :: Maybe (Int, Double)
  , decode :: Maybe (Int, Double)
  , schema :: Text
  , problems :: [Text]
  }

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "measure every served model and write catalogue data"))
  path <- case o.catalogueFile of
    Just p -> pure p
    Nothing -> lookupEnv "OPEN_SLOP_CATALOGUE" >>= maybe (die' "no catalogue: pass --catalogue or set OPEN_SLOP_CATALOGUE") pure
  cat <- eitherDecodeFileStrict path >>= either (die' . T.pack) pure
  client <- newClient
  day <- T.pack . formatTime defaultTimeLocale "%Y-%m-%d" <$> getCurrentTime

  entries <- fmap concat $ forM cat.endpoints \ep ->
    case Map.lookup ep.backend cat.backends of
      Nothing -> say ("skip " <> endpointId ep <> ": no backend " <> ep.backend <> " in the catalogue") >> pure []
      Just b -> do
        listing <- getBody client NoAuth (ep.url <> TE.decodeUtf8 (tagsPath b.engine)) 15
        case listing of
          Left f -> say ("skip " <> endpointId ep <> ": " <> describeFailure f) >> pure []
          Right body -> case parseTags b.engine body of
            Nothing -> say ("skip " <> endpointId ep <> ": unreadable model listing") >> pure []
            Just served -> do
              let wanted = [m.name | m <- served, maybe True (`T.isInfixOf` (endpointId ep <> "/" <> m.name)) o.only]
              fmap catMaybes $ forM wanted \name -> do
                say ("bench " <> endpointId ep <> "/" <> name)
                m <- bench o client ep b name
                report m
                pure (Just (ep.backend, name, entryFor day ep b (lookupModel cat ep.backend name) name m))

  let byBackend =
        Map.fromListWith
          (<>)
          [(bk, [(nm, e)]) | (bk, nm, e) <- entries]
      doc =
        object
          [ "models"
              .= Object
                ( KeyMap.fromList
                    [ (Key.fromText bk, Object (KeyMap.fromList [(Key.fromText nm, e) | (nm, e) <- ms]))
                    | (bk, ms) <- Map.toList byBackend
                    ]
                )
          ]
  case o.out of
    Nothing -> BL.putStr (encode doc) >> putStrLn ""
    Just f -> BL.writeFile f (encode doc) >> say ("wrote " <> T.pack f)

-- | All probes for one model, in order. A failed probe is recorded and the
-- rest still run.
bench :: Opts -> Client -> Endpoint -> Backend -> Text -> IO Measured
bench o client ep b name = do
  win <- windowOf client ep b name
  -- hailo-ollama's window is 2,048 and overflow is silent, so it gets the
  -- small prompt only. Everything else gets both, capped by what the
  -- server says it holds.
  let limit = fromMaybe b.ctx win
      sizes = [n | n <- [1000, 4000], n + 200 < limit, b.engine /= HailoOllama || n <= 1000]
  cold <- forM sizes \n -> do
    nonce <- T.pack . show <$> getPOSIXTime
    r <- ask o client ep b name (filler b n nonce) 1 False
    pure (n, r)
  let prefillPts = [(fromMaybe n pt, isNothing pt, secs) | (n, Right (secs, pt, _, _)) <- cold]
      coldProblems = [T.pack (show n) <> "-token prefill: " <> e | (n, Left e) <- cold]
  warmR <- case reverse sizes of
    [] -> pure Nothing
    (n : _) -> do
      nonce <- T.pack . show <$> getPOSIXTime
      let p = filler b n nonce
      _ <- ask o client ep b name p 1 False
      r <- ask o client ep b name p 1 False
      pure (either (const Nothing) (\(s, pt, _, _) -> Just (fromMaybe n pt, s)) r)
  decR <- ask o client ep b name "Count upward from one in English words, separated by spaces. Do not stop early." (if b.engine == HailoOllama then 64 else 128) False
  let decodePt = case decR of
        Right (s, _, Just ct, _) | ct > 0 -> Just (ct, s)
        _ -> Nothing
  sch <-
    if b.engine == HailoOllama
      then pure "not asked: hailo-ollama answers a format field with HTTP 500"
      else do
        r <- ask o client ep b name "What is two plus two? Reply in the requested JSON." 40 True
        pure case r of
          Left e -> "rejected: " <> T.take 120 e
          Right (_, _, _, content) ->
            case Aeson.decode (BL.fromStrict (TE.encodeUtf8 content)) :: Maybe Value of
              Just (Object km) | KeyMap.member "answer" km -> "honoured"
              _ -> "ignored: the answer did not match the schema"
  pure
    Measured
      { window = win
      , prefill = prefillPts
      , warm = warmR
      , decode = decodePt
      , schema = sch
      , problems = coldProblems <> [e | Left e <- [decR]]
      }

-- | One request, timed by wall clock. Returns seconds, the server's prompt
-- token count if it gave one, the completion token count if it gave one,
-- and the text.
ask :: Opts -> Client -> Endpoint -> Backend -> Text -> Text -> Int -> Bool -> IO (Either Text (Double, Maybe Int, Maybe Int, Text))
ask o client ep b name prompt maxTokens withSchema = do
  t0 <- getPOSIXTime
  r <- case b.engine of
    HailoOllama ->
      postJsonWithin
        (Just o.timeoutSeconds)
        client
        NoAuth
        ep.url
        "/api/generate"
        (object ["model" .= name, "prompt" .= prompt, "stream" .= False, "options" .= object ["num_predict" .= maxTokens]])
    _ ->
      postJsonWithin
        (Just o.timeoutSeconds)
        client
        NoAuth
        ep.url
        "/v1/chat/completions"
        ( object
            ( [ "model" .= name
              , "messages" .= [object ["role" .= ("user" :: Text), "content" .= prompt]]
              , "max_tokens" .= maxTokens
              , "temperature" .= (0 :: Int)
              , "seed" .= (1 :: Int)
              , "stream" .= False
              ]
                <> [ "response_format"
                       .= object
                         [ "type" .= ("json_schema" :: Text)
                         , "json_schema"
                             .= object
                               [ "name" .= ("probe" :: Text)
                               , "strict" .= True
                               , "schema"
                                   .= object
                                     [ "type" .= ("object" :: Text)
                                     , "properties" .= object ["answer" .= object ["type" .= ("string" :: Text)]]
                                     , "required" .= (["answer"] :: [Text])
                                     , "additionalProperties" .= False
                                     ]
                               ]
                         ]
                   | withSchema
                   ]
            )
        )
  t1 <- getPOSIXTime
  let secs = realToFrac (t1 - t0) :: Double
  pure case r of
    Left f -> Left (describeFailure f)
    Right body -> case Aeson.decode body :: Maybe Value of
      Nothing -> Left "the answer was not JSON"
      Just v -> case b.engine of
        HailoOllama -> Right (secs, Nothing, intAt ["eval_count"] v, fromMaybe "" (textAt ["response"] v))
        _ ->
          Right
            ( secs
            , intAt ["usage", "prompt_tokens"] v
            , intAt ["usage", "completion_tokens"] v
            , fromMaybe "" (firstChoice v)
            )
  where
    firstChoice v = case pathTo ["choices"] v of
      Just (Array xs) | (c : _) <- foldr (:) [] xs -> textAt ["message", "content"] c
      _ -> Nothing

-- | What the server says a request can hold.
windowOf :: Client -> Endpoint -> Backend -> Text -> IO (Maybe Int)
windowOf client ep b name = case b.engine of
  LlamaServer -> do
    r <- getBody client NoAuth (ep.url <> "/props") 15
    pure (either (const Nothing) (\body -> Aeson.decode body >>= intAt ["default_generation_settings", "n_ctx"]) r)
  Ollama -> do
    r <- postJsonWithin (Just 15) client NoAuth ep.url "/api/show" (object ["model" .= name])
    pure case r of
      Left _ -> Nothing
      Right body -> do
        v <- Aeson.decode body
        Object mi <- pathTo ["model_info"] v
        case [n | (k, Number n) <- KeyMap.toList mi, ".context_length" `T.isSuffixOf` Key.toText k] of
          (n : _) -> Just (round (toRealFloat n :: Double))
          [] -> Nothing
  HailoOllama -> pure Nothing

-- | A prompt of about n tokens, estimated from the backend's bytes per
-- token, opening with a nonce so no prefix cache can serve it.
filler :: Backend -> Int -> Text -> Text
filler b n nonce =
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
   in "Probe " <> nonce <> ".\n" <> body <> "\nReply with the word ok."

-- | The catalogue.extra entry for one model.
entryFor :: Text -> Endpoint -> Backend -> Maybe Model -> Text -> Measured -> Value
entryFor day ep b known name m =
  Object (KeyMap.fromList (measuredFields <> descriptive))
  where
    decodeRate = fmap (\(n, s) -> fromIntegral n / s) m.decode :: Maybe Double
    measuredFields =
      [ ("tokPerSec", maybe Null (Number . realToFrac . round2) decodeRate)
      , ( "measured"
        , object
            [ "on" .= day
            , "endpoint" .= endpointId ep
            , "engine" .= engineName b.engine
            , "window" .= m.window
            , "prefill"
                .= [ object
                       [ "promptTokens" .= n
                       , "tokensEstimated" .= est
                       , "seconds" .= round2 s
                       , "tokPerSec" .= round2 (fromIntegral n / s)
                       ]
                   | (n, est, s) <- m.prefill
                   ]
            , "warmPrefillSeconds" .= fmap (round2 . snd) m.warm
            , "decode" .= fmap (\(n, s) -> object ["tokens" .= n, "seconds" .= round2 s, "tokPerSec" .= round2 (fromIntegral n / s)]) m.decode
            , "schema" .= m.schema
            , "problems" .= m.problems
            ]
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
    rateLine =
      T.intercalate
        ", "
        ( [T.pack (printf "decode %.2f tok/s" r) | Just r <- [decodeRate]]
            <> [T.pack (printf "prefill %.1f tok/s at %d tokens" (fromIntegral n / s :: Double) n) | (n, _, s) <- take 1 (reverse m.prefill)]
            <> ["schema " <> T.takeWhile (/= ':') m.schema]
        )

report :: Measured -> IO ()
report m = do
  forM_ m.prefill \(n, est, s) ->
    say (T.pack (printf "  prefill %d%s tokens: %.1f s, %.1f tok/s" n (if est then " (estimated)" else "" :: String) s (fromIntegral n / s :: Double)))
  forM_ m.warm \(n, s) -> say (T.pack (printf "  warm %d tokens: %.1f s" n s))
  forM_ m.decode \(n, s) -> say (T.pack (printf "  decode %d tokens: %.1f s, %.2f tok/s" n s (fromIntegral n / s :: Double)))
  say ("  window: " <> maybe "not reported" (T.pack . show) m.window <> "; schema: " <> m.schema)
  forM_ m.problems \p -> say ("  PROBLEM " <> p)
  when (null m.prefill && isNothing m.decode) (say "  nothing measured")

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

round2 :: Double -> Double
round2 x = fromIntegral (round (x * 100) :: Integer) / 100

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-bench: " <>)

die' :: Text -> IO a
die' t = hPutStrLn stderr ("llmq-bench: " <> T.unpack t) >> exitFailure
