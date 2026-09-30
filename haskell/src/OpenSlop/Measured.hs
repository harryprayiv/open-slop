-- | Measurements: what llmq-bench found, kept in the cache of the machine
-- that ran it, and laid over the catalogue every open-slop program reads.
--
-- ============================================================================
-- WHERE THEY LIVE
-- ============================================================================
--
-- One file, $OPEN_SLOP_MEASURED, else $XDG_CACHE_HOME/open-slop/measured.json.
-- It is not configuration: nothing in any Nix evaluation reads it, so a new
-- measurement changes no closure and needs no rebuild, and deleting the
-- file (or clearing the cache) only returns every program to the built
-- catalogue. The catalogue Nix builds keeps what a person wrote about each
-- model; this file keeps what was measured.
--
-- ============================================================================
-- HOW THEY ARE READ
-- ============================================================================
--
-- `loadCatalogue` reads the built catalogue, lays the measurements over it
-- (see `overlay`), and decodes the result. If the overlaid document does
-- not decode, the built catalogue is used alone and the reason is returned
-- as a note, so a damaged cache can never stop llmq from starting.
--
-- ============================================================================
-- WHAT IS STALE
-- ============================================================================
--
-- `decide` says whether a served model needs measuring and why. `pending`
-- asks every endpoint what it serves and applies `decide` to each model, so
-- a program can say that a model has appeared or changed and offer the
-- command that measures it. Nothing in this module starts a measurement.
module OpenSlop.Measured
  ( measuredPath
  , readMeasured
  , emptyMeasured
  , writeAtomic
  , overlay
  , loadCatalogueValue
  , loadCatalogue
  , currentProtocol
  , Policy (..)
  , defaultPolicy
  , Decision (..)
  , decide
  , fingerprintOf
  , mergeInto
  , catalogueKey
  , Pending (..)
  , pending
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM)
import Data.Aeson (FromJSON, Value (..), encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.List (foldl')
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (Day, defaultTimeLocale, diffDays, parseTimeM, showGregorian)
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Http (Auth (..), Client, HttpFailure, getBody)
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, getXdgDirectory, renameFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)

-- | $OPEN_SLOP_MEASURED, else the cache file.
measuredPath :: IO FilePath
measuredPath =
  lookupEnv "OPEN_SLOP_MEASURED" >>= \case
    Just p | not (null p) -> pure p
    _ -> (</> "measured.json") <$> getXdgDirectory XdgCache "open-slop"

emptyMeasured :: Value
emptyMeasured = object ["models" .= object []]

-- | The measurements file, or an empty document when there is none yet.
-- A file that exists and does not parse is an error, never an empty
-- document: treating it as empty would offer to measure everything again
-- and hide the fault.
readMeasured :: FilePath -> IO (Either String Value)
readMeasured f =
  try (B.readFile f) >>= \case
    Left e
      | isDoesNotExistError e -> pure (Right emptyMeasured)
      | otherwise -> throwIO e
    Right bytes -> pure case Aeson.eitherDecodeStrict bytes of
      Left err -> Left (f <> " is not an llmq-bench output: " <> err)
      Right v -> Right v

-- | Written to FILE.tmp and renamed over FILE, so no reader sees half of it.
-- The directory is created if it does not exist.
writeAtomic :: FilePath -> Value -> IO ()
writeAtomic f v = do
  createDirectoryIfMissing True (takeDirectory f)
  BL.writeFile (f <> ".tmp") (encode v)
  renameFile (f <> ".tmp") f

-- | Measurements over a catalogue document. For a model the catalogue
-- describes, the measured entry's top-level fields (tokPerSec, measured)
-- replace the catalogue's and every other field stays. A model the
-- catalogue does not describe is taken only when the measured entry is
-- complete, which llmq-bench makes it by writing a placeholder summary,
-- licence and blurb; otherwise it is skipped and named in the result.
overlay :: Value -> Value -> (Value, [Text])
overlay (Object cat) measured = (Object (KeyMap.insert "models" (Object models') cat), skipped)
  where
    baseModels = objectAt ["models"] (Object cat)
    (models', skipped) = foldl' backendStep (baseModels, []) (KeyMap.toList (objectAt ["models"] measured))
    backendStep (acc, sk) (bk, Object ms) =
      let have = case KeyMap.lookup bk acc of
            Just (Object m) -> m
            _ -> KeyMap.empty
          (have', sk') = foldl' (modelStep bk) (have, sk) (KeyMap.toList ms)
       in (KeyMap.insert bk (Object have') acc, sk')
    backendStep st _ = st
    modelStep bk (have, sk) (nm, entry) = case (KeyMap.lookup nm have, entry) of
      (Just (Object old), Object new) -> (KeyMap.insert nm (Object (KeyMap.union new old)) have, sk)
      (Nothing, Object new)
        | KeyMap.member "summary" new -> (KeyMap.insert nm entry have, sk)
      _ -> (have, sk <> [Key.toText bk <> "/" <> Key.toText nm])
overlay v _ = (v, [])

-- | The built catalogue at the path, with the cached measurements over it,
-- as a document, and notes on anything that was left out.
loadCatalogueValue :: FilePath -> IO (Either String (Value, [Text]))
loadCatalogueValue path =
  Aeson.eitherDecodeFileStrict path >>= \case
    Left err -> pure (Left (path <> ": " <> err))
    Right base -> do
      mpath <- measuredPath
      measured <- try (readMeasured mpath) :: IO (Either SomeException (Either String Value))
      pure . Right $ case measured of
        Left e -> (base, ["could not read " <> T.pack mpath <> " (" <> T.pack (show e) <> "); using the built catalogue"])
        Right (Left err) -> (base, [T.pack err <> "; using the built catalogue"])
        Right (Right m) ->
          let (merged, skipped) = overlay base m
              notes = ["skipped " <> s <> " from " <> T.pack mpath <> ": not in the catalogue and not described" | s <- skipped]
           in case Aeson.fromJSON merged :: Aeson.Result Catalogue of
                Aeson.Success _ -> (merged, notes)
                Aeson.Error e -> (base, [T.pack mpath <> " does not fit the built catalogue (" <> T.pack e <> "); using the built catalogue"])

-- | As 'loadCatalogueValue', decoded.
loadCatalogue :: FilePath -> IO (Either String (Catalogue, [Text]))
loadCatalogue path =
  loadCatalogueValue path >>= \case
    Left err -> pure (Left err)
    Right (v, notes) -> pure case Aeson.fromJSON v of
      Aeson.Success c -> Right (c, notes)
      Aeson.Error e -> Left (path <> ": " <> e)

-- | The version of llmq-bench's measurement protocol. Bumped whenever what
-- is measured, or how, changes, so every entry from before is measured
-- again. 1 was a single sample of each figure. 2 repeated every figure to a
-- confidence target, streamed every request, and recorded the machine's
-- conditions, but judged throttling by the median clock and let the first
-- round start cooler than the rest. 3 paces every timed request to an idle
-- machine under a starting temperature, judges throttling by the mean
-- clock, reports burst and sustained figures apart, and counts a reasoning
-- model's think block.
currentProtocol :: Int
currentProtocol = 3

-- | What counts as stale.
data Policy = Policy
  { maxAgeDays :: Integer
  , wantProbes :: Bool
  , everything :: Bool
  }

defaultPolicy :: Policy
defaultPolicy = Policy {maxAgeDays = 30, wantProbes = True, everything = False}

-- | Whether a model needs measuring, and why, in the words a log or a
-- screen shows.
data Decision = Measure Text | Keep Text
  deriving stock (Eq, Show)

-- | A model is measured when it has no entry, when its entry comes from an
-- older protocol, when the served model's fingerprint differs from the one
-- recorded, when the last run recorded problems, when restraint results
-- are wanted and missing, or when the entry is older than the policy
-- allows.
--
-- An entry written before fingerprints were recorded has none, and then
-- only its age decides: treating the missing fingerprint as a change would
-- offer to measure every model again the first time this ran.
decide :: Policy -> Day -> Maybe Text -> Maybe Value -> Decision
decide p today fp before
  | p.everything = Measure "asked to measure everything"
  | otherwise = case before of
      Nothing -> Measure "never measured"
      Just e
        | maybe True (< currentProtocol) (pathTo ["measured", "protocol", "version"] e >>= fromValue @Int) ->
            Measure "measured with an older protocol"
        | hadProblems e -> Measure "the last run recorded problems"
        | Just recorded <- textAt ["measured", "fingerprint"] e, Just recorded /= fp -> Measure "the served model changed"
        | p.wantProbes && pathTo ["measured", "restraint"] e `elem` [Nothing, Just Null] -> Measure "no restraint results"
        | otherwise -> case measuredOn e of
            Nothing -> Measure "the entry has no date"
            Just d
              | diffDays today d > p.maxAgeDays ->
                  Measure ("measured " <> T.pack (showGregorian d) <> ", over " <> T.pack (show p.maxAgeDays) <> " days ago")
              | otherwise -> Keep ("measured " <> T.pack (showGregorian d))
  where
    hadProblems e = case pathTo ["measured", "problems"] e of
      Just (Array a) -> not (null a)
      _ -> False
    measuredOn e = textAt ["measured", "on"] e >>= parseTimeM True defaultTimeLocale "%Y-%m-%d" . T.unpack

-- | What identifies the exact model a server lists under a name: ollama's
-- digest, else the listed size in bytes. Nothing when the listing carries
-- neither, and then only age decides.
fingerprintOf :: BL.ByteString -> Text -> Maybe Text
fingerprintOf body name = do
  v <- Aeson.decode body :: Maybe Value
  Array ms <- case pathTo ["models"] v of
    Just a -> Just a
    Nothing -> pathTo ["data"] v
  m <- listToMaybe [m | m <- foldr (:) [] ms, textAt ["name"] m == Just name || textAt ["id"] m == Just name]
  case textAt ["digest"] m of
    Just d -> Just d
    Nothing -> (\n -> "size:" <> T.pack (show n)) <$> (pathTo ["size"] m >>= fromValue @Integer)

-- | The earlier measurements with each fresh entry replacing its
-- predecessor whole, and, for every backend whose listing was read, the
-- entries of models it no longer serves removed.
mergeInto :: Value -> Map.Map Text [Text] -> [(Text, Text, Value)] -> Value
mergeInto old listed fresh = object ["models" .= Object (foldl' put pruned fresh)]
  where
    pruned = KeyMap.mapWithKey prune (objectAt ["models"] old)
    prune bk (Object ms) = case Map.lookup (Key.toText bk) listed of
      Just served -> Object (KeyMap.filterWithKey (\k _ -> Key.toText k `elem` served) ms)
      Nothing -> Object ms
    prune _ v = v
    put acc (bk, nm, e) =
      let k = Key.fromText bk
          ms = case KeyMap.lookup k acc of
            Just (Object m) -> m
            _ -> KeyMap.empty
       in KeyMap.insert k (Object (KeyMap.insert (Key.fromText nm) e ms)) acc

-- | The key a model's entry is written under: the served name without
-- ollama's ":latest", which is how the catalogue and catalogue-check name
-- a model registered as "sully" that ollama reports as "sully:latest".
catalogueKey :: Text -> Text
catalogueKey t = maybe t id (T.stripSuffix ":latest" t)

-- | A served model that needs measuring.
data Pending = Pending
  { endpoint :: Text
  -- ^ row/backend
  , model :: Text
  , reason :: Text
  }

-- | Every model the endpoints serve that the policy says needs measuring.
-- An endpoint that does not answer contributes nothing.
pending :: Client -> Catalogue -> Value -> Policy -> Day -> IO [Pending]
pending client cat measured p today =
  concat <$> forM cat.endpoints \ep -> case Map.lookup ep.backend cat.backends of
    Nothing -> pure []
    Just b -> do
      r <- try (getBody client NoAuth (ep.url <> TE.decodeUtf8 (tagsPath b.engine)) 5) :: IO (Either SomeException (Either HttpFailure BL.ByteString))
      pure case r of
        Right (Right body) | Just served <- parseTags b.engine body ->
          catMaybes
            [ case decide p today (fingerprintOf body s.name) (pathTo ["models", ep.backend, catalogueKey s.name] measured) of
                Measure why -> Just (Pending (endpointId ep) s.name why)
                Keep _ -> Nothing
            | s <- served
            ]
        _ -> []

objectAt :: [Text] -> Value -> KeyMap.KeyMap Value
objectAt p v = case pathTo p v of
  Just (Object km) -> km
  _ -> KeyMap.empty

pathTo :: [Text] -> Value -> Maybe Value
pathTo [] v = Just v
pathTo (k : ks) (Object o) = KeyMap.lookup (Key.fromText k) o >>= pathTo ks
pathTo _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt p v = case pathTo p v of
  Just (String t) -> Just t
  _ -> Nothing

fromValue :: forall a. (FromJSON a) => Value -> Maybe a
fromValue = parseMaybe Aeson.parseJSON