-- | How much one request to one model may hold, worked out from what the
-- server says, what llmq-bench measured, and what the operator configured,
-- in that order of authority. Nothing in here is a fixed number for a
-- particular model or machine.
--
-- ============================================================================
-- THE WINDOW
-- ============================================================================
--
-- llama-server allocates its context when it starts, and /props reports it,
-- so that figure is the window. ollama allocates per request from num_ctx;
-- the model's trained context (from /api/show) is the most it can use, and
-- the catalogue's ctx for the model, else for the backend, is the most the
-- operator lets it allocate on this hardware. The window is the smaller of
-- the two. hailo-ollama's zoo models all have 2048.
--
-- So a 128K model on a machine whose catalogue says 131072 gets 128K, and
-- the same model on a Pi whose catalogue says 16384 gets 16K. Raising the
-- limit for new hardware is a catalogue change, not a code change.
--
-- ============================================================================
-- CHARACTERS PER TOKEN
-- ============================================================================
--
-- Budgets are counted in characters because the text is in hand before the
-- server tokenises it. The ratio is the model's own, measured: by llmq-bench
-- (measured.charsPerToken), and refined during use by 'learn' from the
-- prompt token counts servers report with every answer. The catalogue's
-- backend figure is the fallback for a model nothing has measured yet, and
-- 'cptSource' says which one is in use.
--
-- ============================================================================
-- NO OUTPUT CAP
-- ============================================================================
--
-- Nothing here limits how long an answer may be. A request reserves room
-- for its answer when it decides how much history or how many sources to
-- send ('answerRoom'), and the answer may then run until the model stops or
-- the window is full. 'unlimitedPredict' is the per-engine way of saying so.
module OpenSlop.Capacity
  ( Capacity (..)
  , WindowSource (..)
  , CptSource (..)
  , probeWindow
  , capacityFor
  , measuredEntry
  , answerRoom
  , promptChars
  , promptCharsWithin
  , learn
  , unlimitedPredict
  , describeCapacity
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue (Backend (..), Engine (..), Model (..))
import OpenSlop.Http (Auth (..), Client, getBody, postJsonWithin)
import Text.Printf (printf)

data WindowSource
  = ServerAllocated
  -- ^ llama-server's n_ctx
  | TrainedAndConfigured
  -- ^ the smaller of the trained context and the catalogue's ctx
  | ConfiguredOnly
  -- ^ the server reported nothing; the catalogue's ctx
  deriving stock (Eq, Show)

data CptSource = Learned | Benchmarked | CatalogueGuess
  deriving stock (Eq, Show)

data Capacity = Capacity
  { window :: Int
  -- ^ tokens one request may hold, prompt and answer together
  , windowSource :: WindowSource
  , charsPerToken :: Double
  , cptSource :: CptSource
  , prefillTokPerSec :: Maybe Double
  -- ^ measured, at the largest prompt size measured
  , decodeTokPerSec :: Maybe Double
  }
  deriving stock (Show)

-- | What the server says about the window. llama-server: the context it
-- allocated. ollama: the model's trained context. hailo-ollama: 2048.
probeWindow :: Client -> Engine -> Text -> Text -> IO (Maybe Int)
probeWindow client engine url model = case engine of
  LlamaServer -> do
    r <- getBody client NoAuth (url <> "/props") 15
    pure (either (const Nothing) (\body -> Aeson.decode body >>= intAt ["default_generation_settings", "n_ctx"]) r)
  Ollama -> do
    r <- postJsonWithin (Just 15) client NoAuth url "/api/show" (object ["model" .= model])
    pure case r of
      Left _ -> Nothing
      Right body -> do
        v <- Aeson.decode body
        Object mi <- pathTo ["model_info"] v
        case [n | (k, Number n) <- KeyMap.toList mi, ".context_length" `T.isSuffixOf` Key.toText k] of
          (n : _) -> Just (round (toRealFloat n :: Double))
          [] -> Nothing
  HailoOllama -> pure (Just 2048)

-- | The measured entry for a model in a measurements document, under
-- models.<backend>.<name>, tolerating ollama's ":latest".
measuredEntry :: Value -> Text -> Text -> Maybe Value
measuredEntry doc backend name =
  case pathTo ["models", backend, name, "measured"] doc of
    Just v -> Just v
    Nothing -> pathTo ["models", backend, fromMaybe name (T.stripSuffix ":latest" name), "measured"] doc

-- | Put the pieces together. The server's figure, the catalogue entries and
-- the measured entry may each be missing.
capacityFor :: Backend -> Maybe Model -> Maybe Value -> Maybe Int -> Capacity
capacityFor b m measured served =
  Capacity
    { window
    , windowSource
    , charsPerToken = maybe b.charsPerToken fst cpt
    , cptSource = maybe CatalogueGuess snd cpt
    , prefillTokPerSec = measured >>= largestPrefill
    , decodeTokPerSec = measured >>= numAt ["decode", "tokPerSec"]
    }
  where
    configured = fromMaybe b.ctx (m >>= (.ctx))
    (window, windowSource) = case (b.engine, served) of
      (LlamaServer, Just n) -> (n, ServerAllocated)
      (HailoOllama, Just n) -> (n, ServerAllocated)
      (_, Just n) -> (min n configured, TrainedAndConfigured)
      (_, Nothing) -> (configured, ConfiguredOnly)
    cpt = do
      v <- measured >>= numAt ["charsPerToken"]
      if v > 0.5 && v < 20 then Just (v, Benchmarked) else Nothing
    largestPrefill v = case pathTo ["prefill"] v of
      Just (Array rows) ->
        case [(pt, r) | row <- foldr (:) [] rows, Just pt <- [numAt ["promptTokens"] row], Just r <- [numAt ["tokPerSec"] row]] of
          [] -> Nothing
          xs -> Just (snd (maximum xs))
      _ -> Nothing

-- | Tokens set aside for the answer when deciding how much to send: a
-- quarter of the window, and at least 512. The answer is not cut
-- off there; it may use whatever the prompt left.
answerRoom :: Capacity -> Int
answerRoom c = max 512 (c.window `div` 4)

-- | Characters of prompt that fit with the answer room and a fixed overhead
-- for the template and instructions kept free.
promptChars :: Capacity -> Int -> Int
promptChars c overheadTokens =
  max 0 (floor (fromIntegral (c.window - answerRoom c - overheadTokens) * c.charsPerToken))

-- | The same, further limited so that reading the prompt should take no
-- longer than the given seconds at the measured prefill rate. With no
-- measured rate, the window alone decides.
promptCharsWithin :: Capacity -> Int -> Maybe Double -> Int
promptCharsWithin c overheadTokens maxWait = case (maxWait, c.prefillTokPerSec) of
  (Just secs, Just rate) -> min (promptChars c overheadTokens) (floor (secs * rate * c.charsPerToken))
  _ -> promptChars c overheadTokens

-- | Refine characters per token from a request the server counted. The
-- new figure is a running blend weighted toward what has been seen, so one
-- odd prompt does not swing it. A count far from the current figure is
-- ignored: servers that reuse a cached prefix count only the tokens they
-- evaluated, which makes the ratio look several times too high.
learn :: Capacity -> Int -> Int -> Capacity
learn c chars tokens
  | tokens < 32 || chars < 64 = c
  | observed < 0.5 * c.charsPerToken || observed > 2 * c.charsPerToken = c
  | otherwise =
      let blended = case c.cptSource of
            CatalogueGuess -> observed
            _ -> 0.7 * c.charsPerToken + 0.3 * observed
       in c {charsPerToken = blended, cptSource = Learned}
  where
    observed = fromIntegral chars / fromIntegral tokens :: Double

-- | The option that lets an answer run until the model stops or the window
-- is full. ollama: num_predict -2 fills the context. llama-server's native
-- route: n_predict -1. The OpenAI route takes no max_tokens at all.
-- hailo-ollama has no such value, so it gets what the window leaves.
unlimitedPredict :: Engine -> Capacity -> Int -> Maybe (Text, Int)
unlimitedPredict engine c promptTokens = case engine of
  Ollama -> Just ("num_predict", -2)
  LlamaServer -> Nothing
  HailoOllama -> Just ("num_predict", max 64 (c.window - promptTokens))

describeCapacity :: Capacity -> Text
describeCapacity c =
  T.pack $
    printf
      "window %d tokens (%s), %.2f chars/token (%s)%s%s"
      c.window
      (case c.windowSource of
        ServerAllocated -> "allocated by the server" :: String
        TrainedAndConfigured -> "trained context within the catalogue's limit"
        ConfiguredOnly -> "the catalogue's limit; the server reported none")
      c.charsPerToken
      (case c.cptSource of
        Learned -> "learned from this session" :: String
        Benchmarked -> "measured by llmq-bench"
        CatalogueGuess -> "the catalogue's guess; run llmq-bench")
      (maybe "" (printf ", prefill %.1f tok/s") c.prefillTokPerSec :: String)
      (maybe "" (printf ", decode %.1f tok/s") c.decodeTokPerSec :: String)

pathTo :: [Text] -> Value -> Maybe Value
pathTo [] v = Just v
pathTo (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= pathTo ks
pathTo _ _ = Nothing

intAt :: [Text] -> Value -> Maybe Int
intAt p v = round <$> numAt p v

numAt :: [Text] -> Value -> Maybe Double
numAt p v = case pathTo p v of
  Just (Number n) -> Just (toRealFloat n)
  _ -> Nothing
