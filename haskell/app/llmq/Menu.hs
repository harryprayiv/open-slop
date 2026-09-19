-- | llmq's view of the fleet: the catalogue joined with what the servers
-- reported, the cards and previews, name resolution, and the fzf menu.
module Menu
  ( Entry (..)
  , Probe (..)
  , probe
  , card
  , preview
  , resolve
  , pickWithFzf
  , chooseEntry
  , say
  , die'
  , tshow
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Http
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit
import System.FilePath ((</>))
import System.IO
import System.Process.Typed


data Entry = Entry
  { entryId :: Text
  -- ^ row/backend/name
  , endpoint :: Endpoint
  , engine :: Engine
  , streams :: Bool
  , name :: Text
  , summary :: Text
  , docFit :: DocFit
  , budget :: Budget
  , tokPerSec :: Maybe Double
  , licence :: Text
  , blurb :: Text
  , backendBlurb :: Text
  }

data Probe = Probe
  { entries :: [Entry]
  , unavailable :: [Text]
  }

probe :: Client -> Auth -> Catalogue -> IO Probe
probe client auth cat = do
  results <- forM cat.endpoints \ep ->
    case Map.lookup ep.backend cat.backends of
      Nothing -> pure (Left (endpointId ep <> ": no such backend in the catalogue"))
      Just b -> do
        r <- getBody client auth (ep.url <> TE.decodeUtf8 (tagsPath b.engine)) 8
        pure case r of
          Left f -> Left (endpointId ep <> ": no answer from " <> ep.url <> " (" <> describeFailure f <> ")")
          Right body -> case parseTags b.engine body of
            Nothing -> Left (endpointId ep <> ": unreadable model list from " <> ep.url)
            Just served -> Right (ep, b, served)
  let ups = [x | Right x <- results]
      downs = [e | Left e <- results]
      entries =
        sortOn (\e -> (endpointId e.endpoint, e.docFit, e.name)) $
          concat
            [ [ Entry
                  { entryId = endpointId ep <> "/" <> sm.name
                  , endpoint = ep
                  , engine = b.engine
                  , streams = b.streams
                  , name = sm.name
                  , summary = maybe "NO CATALOGUE ENTRY" (.summary) m
                  , docFit = maybe Unknown (.docFit) m
                  , budget = maybe (backendBudget b) (modelBudget b) m
                  , tokPerSec = m >>= (.tokPerSec)
                  , licence = maybe "unknown" (.licence) m
                  , blurb =
                      maybe
                        ("The catalogue has no entry for this model. The budget below is the " <> ep.backend <> " backend's default.\n")
                        (.blurb)
                        m
                  , backendBlurb = b.blurb
                  }
              | sm <- served
              , let m = lookupModel cat ep.backend sm.name
              ]
            | (ep, b, served) <- ups
            ]
      notServed =
        [ endpointId ep <> "/" <> n <> ": in the catalogue, not served"
        | (ep, _, served) <- ups
        , n <- Map.keys (fromMaybe Map.empty (Map.lookup ep.backend cat.models))
        , n `notElem` map (\s -> fromMaybe s.name (T.stripSuffix ":latest" s.name)) served
        ]
  pure Probe {entries, unavailable = downs <> notServed}

card :: Entry -> Text
card e =
  T.unlines
    [ e.entryId
    , e.summary
    , ""
    , T.stripEnd e.blurb
    , "window     " <> tshow e.budget.ctx <> " tokens, " <> tshow e.budget.predict <> " of them reserved for output"
    , "input      " <> tshow e.budget.chunkBytes <> " bytes per request"
    , "measured   " <> maybe "no generation rate measured here" (\r -> tshow r <> " tok/s generation on this hardware") e.tokPerSec
    , "docs fit   " <> fitName e.docFit
    , "licence    " <> e.licence
    ]

fitName :: DocFit -> Text
fitName = T.toLower . tshow

preview :: Entry -> Text
preview e = card e <> "\nbackend    " <> e.endpoint.backend <> ", " <> engineName e.engine <> "\n\n" <> T.stripEnd e.backendBlurb <> "\n"

resolve :: Probe -> Text -> Either Text Entry
resolve p q = case filter matches p.entries of
  [e] -> Right e
  [] -> Left ("no served model matches '" <> q <> "' (llmq list)")
  _ -> Left ("'" <> q <> "' matches more than one model; use ROW/BACKEND/NAME")
  where
    matches e =
      let i = fromMaybe e.entryId (T.stripSuffix ":latest" e.entryId)
       in i == q || ("/" <> q) `T.isSuffixOf` i

-- | The fzf menu. Each row carries its index in a hidden first field; the
-- preview pane cats a file named by that index.
pickWithFzf :: Probe -> IO (Maybe Entry)
pickWithFzf p = do
  let w = maximum (19 : map (T.length . (.entryId)) p.entries) + 2
      pad n t = t <> T.replicate (n - T.length t) " "
      header =
        T.intercalate
          "\n"
          ( (pad w "ROW/BACKEND/MODEL" <> pad 12 "DOCS FIT" <> "SUMMARY")
              : ["unavailable  " <> u | u <- p.unavailable]
          )
      rows =
        T.unlines
          [ tshow i <> "\t" <> pad w e.entryId <> pad 12 (fitName e.docFit) <> e.summary
          | (i, e) <- zip [0 :: Int ..] p.entries
          ]
  tmpRoot <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
  let tmp = tmpRoot </> "llmq-preview"
  createDirectoryIfMissing True tmp
  forM_ (zip [0 :: Int ..] p.entries) \(i, e) -> TIO.writeFile (tmp </> show i) (preview e)
  (code, outBs, _) <-
    readProcess
      ( setStdin (byteStringInput (BL.fromStrict (TE.encodeUtf8 rows)))
          . setStderr inherit
          $ proc
            "fzf"
            [ "--prompt=model > "
            , "--height=90%"
            , "--layout=reverse"
            , "--border"
            , "--delimiter=\t"
            , "--with-nth=2"
            , "--header=" <> T.unpack header
            , "--preview=cat " <> tmp <> "/{1}"
            , "--preview-window=right:50%:wrap"
            ]
      )
  pure case code of
    ExitSuccess ->
      let sel = T.takeWhile (/= '\t') (TE.decodeUtf8 (BL.toStrict outBs))
       in case reads (T.unpack sel) of
            [(i, _)] | i < length p.entries -> Just (p.entries !! i)
            _ -> Nothing
    _ -> Nothing


chooseEntry :: Probe -> Maybe Text -> IO Entry
chooseEntry p = \case
  Just q -> either die' pure (resolve p q)
  Nothing -> do
    when (null p.entries) do
      mapM_ (say . ("unavailable  " <>)) p.unavailable
      die' "no server reported any model"
    tty <- hIsTerminalDevice stdin
    unless tty (die' "no terminal for the menu; pass -m")
    pickWithFzf p >>= maybe (say "nothing selected" >> exitSuccess) pure

say :: Text -> IO ()
say t = TIO.hPutStrLn stderr ("llmq: " <> t)

die' :: Text -> IO a
die' t = say t >> exitFailure

tshow :: (Show a) => a -> Text
tshow = T.pack . show
