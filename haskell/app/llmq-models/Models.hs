-- | The catalogue, read into one row per model, and how rows sort.
--
-- Part of llmq-models; Main describes the program. Every number here comes
-- from the `measured` block llmq-bench writes into the catalogue.
module Models
  ( Probe (..)
  , Row (..)
  , Feel (..)
  , feelOf
  , feelName
  , stiffness
  , rowsOf
  , SortKey (..)
  , sortName
  , sortRows
  ) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAlphaNum, isDigit, toLower)
import Data.List (sortBy)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Text.Read (readMaybe)

data Probe = Probe
  { name :: Text
  , refused :: Bool
  , answer :: Text
  }

data Row = Row
  { backend :: Text
  , model :: Text
  , decode :: Maybe Double
  , prefill :: Maybe (Int, Double)
  , warm :: Maybe Double
  , load :: Maybe Double
  , loadNote :: Text
  , window :: Maybe Int
  , schema :: Text
  , params :: Maybe (Double, Bool)
  -- ^ billions, and whether the server reported it exactly
  , quant :: Text
  , family :: Text
  , sizeBytes :: Maybe Double
  , docFit :: Text
  , licence :: Text
  , summary :: Text
  , measuredOn :: Text
  , problems :: [Text]
  , probes :: [Probe]
  , charsPerToken :: Double
  }

data Feel = Conversational | Readable | Batch | Unmeasured
  deriving stock (Eq)

feelOf :: Row -> Feel
feelOf r = case r.decode of
  Nothing -> Unmeasured
  Just d
    | d >= 5 -> Conversational
    | d >= 2 -> Readable
    | otherwise -> Batch

feelName :: Feel -> Text
feelName = \case
  Conversational -> "conversational"
  Readable -> "readable"
  Batch -> "batch"
  Unmeasured -> "unmeasured"

-- | Refusals among the probes that measure stiffness: all but "opinion".
stiffness :: Row -> Maybe (Int, Int)
stiffness r = case [p | p <- r.probes, p.name /= "opinion"] of
  [] -> Nothing
  ps -> Just (length [() | p <- ps, p.refused], length ps)

rowsOf :: Value -> [Row]
rowsOf doc =
  [ rowOf (fromMaybe 3.5 (num ["backends", bk, "charsPerToken"] doc)) bk nm e
  | Just (Object backends) <- [at ["models"] doc]
  , (bkKey, Object ms) <- KeyMap.toList backends
  , (nmKey, e) <- KeyMap.toList ms
  , let bk = Key.toText bkKey
  , let nm = Key.toText nmKey
  ]

rowOf :: Double -> Text -> Text -> Value -> Row
rowOf cpt bk nm e =
  Row
    { backend = bk
    , model = nm
    , decode = num ["measured", "decode", "tokPerSec"] e
    , prefill = largestPrefill
    , warm = num ["measured", "warmPrefillSeconds"] e
    , load = num ["measured", "load", "seconds"] e
    , loadNote = fromMaybe "" (txt ["measured", "load", "method"] e)
    , window = round <$> num ["measured", "window"] e
    , schema = maybe "-" (T.strip . T.takeWhile (/= ':')) (txt ["measured", "schema"] e)
    , params = case num ["measured", "facts", "parameterCount"] e of
        Just n -> Just (n / 1e9, True)
        Nothing -> (,False) <$> (paramsFrom nm `orElse` (txt ["summary"] e >>= paramsFrom))
    , quant = fromMaybe "" (txt ["measured", "facts", "quantization"] e)
    , family = fromMaybe "" (txt ["measured", "facts", "family"] e)
    , sizeBytes = num ["measured", "facts", "sizeBytes"] e
    , docFit = fromMaybe "-" (txt ["docFit"] e)
    , licence = fromMaybe "-" (txt ["licence"] e)
    , summary = fromMaybe "" (txt ["summary"] e)
    , measuredOn = fromMaybe "" (txt ["measured", "on"] e)
    , problems = case at ["measured", "problems"] e of
        Just (Array xs) -> [t | String t <- foldr (:) [] xs]
        _ -> []
    , probes = case at ["measured", "restraint", "probes"] e of
        Just (Array xs) -> mapMaybe probeOf (foldr (:) [] xs)
        _ -> []
    , charsPerToken = cpt
    }
  where
    largestPrefill = case at ["measured", "prefill"] e of
      Just (Array xs) -> listToMaybe (sortBy (comparing (Down . fst)) (mapMaybe point (foldr (:) [] xs)))
      _ -> Nothing
    point v = (,) <$> (round <$> num ["promptTokens"] v) <*> num ["tokPerSec"] v
    probeOf v = do
      n <- txt ["probe"] v
      Bool r <- at ["refused"] v
      pure (Probe n r (fromMaybe "" (txt ["answer"] v)))
    orElse a b = maybe b Just a

-- | Billions of parameters from a name like "qwen2.5-coder:7b" or a summary
-- like "Qwen2.5-7B-Instruct": the first word-piece that is a number followed
-- by b. "gemma2" and "qwen2.5" are not, because nothing follows with a b.
paramsFrom :: Text -> Maybe Double
paramsFrom t =
  listToMaybe
    [ n
    | piece <- T.split (\c -> not (isAlphaNum c || c == '.')) (T.map toLower t)
    , Just digits <- [T.stripSuffix "b" piece]
    , not (T.null digits)
    , T.all (\c -> isDigit c || c == '.') digits
    , Just n <- [readMaybe (T.unpack (if T.head digits == '.' then "0" <> digits else digits))]
    , n > 0
    ]

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


data SortKey = ByDecode | ByPrefill | ByLoad | ByParams | ByRestraint | ByName
  deriving stock (Eq, Enum, Bounded)

sortName :: SortKey -> Text
sortName = \case
  ByDecode -> "decode"
  ByPrefill -> "prefill"
  ByLoad -> "load"
  ByParams -> "params"
  ByRestraint -> "restraint"
  ByName -> "name"

-- | Unmeasured rows always sort last, whichever direction is chosen.
sortRows :: SortKey -> Bool -> [Row] -> [Row]
sortRows key reversed = sortBy cmp
  where
    cmp a b = case key of
      ByName -> flipIf (comparing (\r -> (r.backend, r.model)) a b)
      ByDecode -> big (.decode) a b
      ByPrefill -> big (fmap snd . (.prefill)) a b
      ByLoad -> small (.load) a b
      ByParams -> big (fmap fst . (.params)) a b
      ByRestraint -> small (fmap (\(n, _) -> fromIntegral n :: Double) . stiffness) a b
    flipIf o = if reversed then compare EQ o else o
    big f = measured (\x y -> compare (Down x) (Down y)) f
    small f = measured compare f
    measured c f a b = case (f a, f b) of
      (Just x, Just y) -> flipIf (c x y)
      (Just _, Nothing) -> LT
      (Nothing, Just _) -> GT
      (Nothing, Nothing) -> comparing (.model) a b
