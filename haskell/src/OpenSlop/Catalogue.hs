-- | The catalogue: backends, the models they serve, and the per-request
-- budget each model gets.
--
-- Nix owns the data (catalogue/default.nix) and hands it over as JSON. This
-- module owns its meaning: what a window is, how a budget is derived from
-- one, and which engine speaks to which backend. Nothing in here does IO.
module OpenSlop.Catalogue
  ( Engine (..)
  , Backend (..)
  , Model (..)
  , DocFit (..)
  , Endpoint (..)
  , Catalogue (..)
  , Budget (..)
  , budgetFor
  , modelBudget
  , backendBudget
  , engineName
  , lookupModel
  , endpointId
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | The three server dialects the fleet speaks. Each constructor has its own
-- request shape and response shape in "OpenSlop.Engine"; a request for one
-- cannot be built for another.
data Engine
  = Ollama
  | HailoOllama
  | LlamaServer
  deriving stock (Eq, Ord, Show, Generic)

engineName :: Engine -> Text
engineName = \case
  Ollama -> "ollama"
  HailoOllama -> "hailo-ollama"
  LlamaServer -> "llama-server"

instance FromJSON Engine where
  parseJSON = withText "Engine" \case
    "ollama" -> pure Ollama
    "hailo-ollama" -> pure HailoOllama
    "llama-server" -> pure LlamaServer
    other -> fail ("unknown engine: " <> T.unpack other)

instance ToJSON Engine where
  toJSON = Aeson.String . engineName

data DocFit = Best | Usable | Poor | Unsuitable | Unknown
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON DocFit where
  parseJSON = withText "DocFit" \case
    "best" -> pure Best
    "usable" -> pure Usable
    "poor" -> pure Poor
    "unsuitable" -> pure Unsuitable
    "unknown" -> pure Unknown
    other -> fail ("unknown docFit: " <> T.unpack other)

instance ToJSON DocFit where
  toJSON = Aeson.String . \case
    Best -> "best"
    Usable -> "usable"
    Poor -> "poor"
    Unsuitable -> "unsuitable"
    Unknown -> "unknown"

-- | One backend as the catalogue describes it. Field names match the Nix
-- attribute names so the JSON needs no renaming.
data Backend = Backend
  { engine :: Engine
  , port :: Int
  , streams :: Bool
  , acceptsOptions :: Bool
  , ctx :: Int
  , predict :: Int
  , promptOverhead :: Int
  , charsPerToken :: Double
  , temperature :: Maybe Double
  , blurb :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One model. @ctx@ and @predict@ override the backend's when present.
data Model = Model
  { summary :: Text
  , docFit :: DocFit
  , ctx :: Maybe Int
  , predict :: Maybe Int
  , tokPerSec :: Maybe Double
  , licence :: Text
  , blurb :: Text
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A server to talk to: a row's address plus one of its backends. Nix builds
-- these from the consumer's endpoint options; the catalogue never contains an
-- address.
data Endpoint = Endpoint
  { row :: Text
  , backend :: Text
  , url :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

endpointId :: Endpoint -> Text
endpointId e = e.row <> "/" <> e.backend

data Catalogue = Catalogue
  { endpoints :: [Endpoint]
  , backends :: Map Text Backend
  , models :: Map Text (Map Text Model)
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one request may hold.
data Budget = Budget
  { ctx :: Int
  -- ^ tokens the server holds, prompt and output together
  , predict :: Int
  -- ^ output tokens reserved inside ctx
  , chunkBytes :: Int
  -- ^ input bytes per request
  , bytesPerToken :: Double
  , temperature :: Maybe Double
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | floor((ctx - predict - promptOverhead) * charsPerToken), as the Nix
-- version computed it, so a job started under the bash llmq and one started
-- here cut the same parts.
budgetFor :: Backend -> Int -> Int -> Budget
budgetFor b ctx predict =
  Budget
    { ctx
    , predict
    , chunkBytes = floor (fromIntegral (ctx - predict - b.promptOverhead) * b.charsPerToken)
    , bytesPerToken = b.charsPerToken
    , temperature = b.temperature
    }

backendBudget :: Backend -> Budget
backendBudget b = budgetFor b b.ctx b.predict

modelBudget :: Backend -> Model -> Budget
modelBudget b m = budgetFor b (maybe b.ctx id m.ctx) (maybe b.predict id m.predict)

-- | Look a served name up in the catalogue, tolerating ollama's ":latest".
lookupModel :: Catalogue -> Text -> Text -> Maybe Model
lookupModel c backendName served = do
  ms <- Map.lookup backendName c.models
  case Map.lookup served ms of
    Just m -> Just m
    Nothing -> Map.lookup (stripLatest served) ms
  where
    stripLatest t = maybe t id (T.stripSuffix ":latest" t)
