-- | Which backend a request's model field names.
--
-- The gateway answers for every model the servers behind it report, under
-- the same ids llmq uses: row/backend/name, and any suffix of that which is
-- unique, with ollama's ":latest" optional. A model the catalogue has no
-- entry for is still served, with its backend's default budget, the same
-- as llmq does.
module OpenSlop.Gateway.Route
  ( Target (..)
  , targetId
  , Listing
  , resolveTarget
  ) where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue

data Target = Target
  { endpoint :: Endpoint
  , backend :: Backend
  , name :: Text
  -- ^ the name the server knows the model by
  , budget :: Budget
  }
  deriving stock (Show)

targetId :: Target -> Text
targetId t = endpointId t.endpoint <> "/" <> t.name

-- | What each reachable endpoint serves, by the names it reports.
type Listing = [(Endpoint, [Text])]

resolveTarget :: Catalogue -> Listing -> Text -> Either Text Target
resolveTarget cat listing q =
  case filter matches candidates of
    [t] -> Right t
    [] -> Left ("no served model matches '" <> q <> "'; GET /v1/models lists them")
    ts -> Left ("'" <> q <> "' matches " <> T.intercalate ", " (map targetId ts) <> "; use row/backend/name")
  where
    candidates =
      [ Target {endpoint = ep, backend = b, name = n, budget = maybe (backendBudget b) (modelBudget b) (lookupModel cat ep.backend n)}
      | (ep, names) <- listing
      , Just b <- [Map.lookup ep.backend cat.backends]
      , n <- names
      ]
    stripLatest t = fromMaybe t (T.stripSuffix ":latest" t)
    q' = stripLatest q
    matches t =
      let i = stripLatest (targetId t)
       in i == q' || ("/" <> q') `T.isSuffixOf` i