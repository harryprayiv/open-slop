-- | open-slop-gateway: one authenticated OpenAI-compatible endpoint in front
-- of a row's inference servers.
--
-- The catalogue it reads is the same JSON llmq reads, with endpoints that
-- point at the servers on this machine (normally loopback). Clients send
-- the ids llmq shows, row/backend/name, in the model field.
--
-- TLS is on when --tls-cert and --tls-key are given. Without them the
-- gateway binds loopback only, unless --plaintext-lan says otherwise: a
-- bearer key sent in clear on a LAN is readable by anything on it, and that
-- is a choice made once, by name, on the command line.
--
-- --record FILE appends one JSON object per chat request to FILE: who,
-- which model, schema or not, messages, bytes, whether it was a repair,
-- tokens, seconds and outcome. llmq-grace --measure reads it to attribute
-- a Grace program's calls to the program; see OpenSlop.Gateway.Server.
--
-- --web DIR serves the built web page (open-slop's web/ directory, the
-- flake's web output) at /, beside the API it calls; it needs --index.
--
-- --index serves llmq-index's database as the models index and index/NAME
-- (see OpenSlop.Gateway.Server). Its settings default to the variables
-- llmq-index reads, which programs.llmq sets on the machine that holds the
-- database: $OPEN_SLOP_RAG_DB, _EMBED_AT, _EMBED_MODEL, _CHAT_AT,
-- _CHAT_MODEL, _RERANK_AT and _RERANK_MODEL. So the gateway that serves the
-- index runs where the database is (blade), with a catalogue whose
-- endpoints are the inference rows on the LAN, and its index answers come
-- from the same servers llmq-index there uses. Every server it sends text
-- to is checked to be on the LAN, as in llmq-index.
module Main (main) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (forM)
import Data.Aeson (eitherDecodeFileStrict, encode)
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WarpTLS qualified as WarpTLS
import OpenSlop.Catalogue (Catalogue (..), endpointId)
import OpenSlop.Gateway.Keys (keyCount, parseKeys)
import OpenSlop.Gateway.Asks (newAsks)
import OpenSlop.Gateway.Server (app, newEnv)
import OpenSlop.Http (newClient)
import OpenSlop.Rag.Ask (AskConfig (..), askingFrom, defaultAskConfig)
import OpenSlop.Rag.Store (connectStore, migrate)
import System.Environment (lookupEnv)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO

data Opts = Opts
  { catalogueFile :: FilePath
  , keysFile :: FilePath
  , host :: String
  , port :: Int
  , tlsCert :: Maybe FilePath
  , tlsKey :: Maybe FilePath
  , plaintextLan :: Bool
  , recordFile :: Maybe FilePath
  , index :: Maybe IndexOpts
  , webDir :: Maybe FilePath
  }

data IndexOpts = IndexOpts
  { indexDb :: Maybe String
  , indexEmbedAt :: Maybe String
  , indexEmbedModel :: Maybe String
  , indexChatAt :: Maybe String
  , indexChatModel :: Maybe String
  , indexRerankAt :: Maybe String
  , indexRerankModel :: Maybe String
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> strOption (long "catalogue" <> metavar "FILE" <> help "catalogue JSON whose endpoints are the servers this gateway fronts")
    <*> strOption (long "keys" <> metavar "FILE" <> help "one `name key` per line")
    <*> strOption (long "host" <> metavar "ADDR" <> value "127.0.0.1" <> showDefault)
    <*> option auto (long "port" <> metavar "PORT" <> value 8443 <> showDefault)
    <*> optional (strOption (long "tls-cert" <> metavar "FILE"))
    <*> optional (strOption (long "tls-key" <> metavar "FILE"))
    <*> switch (long "plaintext-lan" <> help "allow a non-loopback bind without TLS; keys then cross the network in clear")
    <*> optional (strOption (long "record" <> metavar "FILE" <> help "append one JSON line per chat request, for llmq-grace --measure"))
    <*> optional
      ( flag' () (long "index" <> help "serve llmq-index's database as the models index and index/NAME")
          *> ( IndexOpts
                 <$> optional (strOption (long "index-db" <> metavar "CONNINFO" <> help "default $OPEN_SLOP_RAG_DB, else dbname=llmq_rag"))
                 <*> optional (strOption (long "index-embed-at" <> metavar "ROW/BACKEND" <> help "default $OPEN_SLOP_RAG_EMBED_AT"))
                 <*> optional (strOption (long "index-embed-model" <> metavar "NAME" <> help "default $OPEN_SLOP_RAG_EMBED_MODEL"))
                 <*> optional (strOption (long "index-chat-at" <> metavar "ROW/BACKEND" <> help "default $OPEN_SLOP_RAG_CHAT_AT"))
                 <*> optional (strOption (long "index-model" <> metavar "NAME" <> help "the chat model that answers; default $OPEN_SLOP_RAG_CHAT_MODEL"))
                 <*> optional (strOption (long "index-rerank-at" <> metavar "ROW/BACKEND" <> help "default $OPEN_SLOP_RAG_RERANK_AT; unset means no reranking"))
                 <*> optional (strOption (long "index-rerank-model" <> metavar "NAME" <> help "default $OPEN_SLOP_RAG_RERANK_MODEL"))
             )
      )
    <*> optional (strOption (long "web" <> metavar "DIR" <> help "serve the built web page from DIR at /; needs --index"))

main :: IO ()
main = do
  hSetBuffering stderr LineBuffering
  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "OpenAI-compatible gateway in front of ollama, hailo-ollama and llama-server"))
  cat <- eitherDecodeFileStrict o.catalogueFile >>= either (dieWith . T.pack) pure
  keysText <- TIO.readFile o.keysFile
  keys <- either dieWith pure (parseKeys keysText)
  let loopback = o.host `elem` ["127.0.0.1", "::1", "localhost"]
  tls <- case (o.tlsCert, o.tlsKey) of
    (Just c, Just k) -> pure (Just (c, k))
    (Nothing, Nothing)
      | loopback || o.plaintextLan -> pure Nothing
      | otherwise -> dieWith ("refusing to bind " <> T.pack o.host <> " without TLS: bearer keys would cross the network in clear. Pass --tls-cert and --tls-key, or --plaintext-lan to accept that.")
    _ -> dieWith "--tls-cert and --tls-key go together"
  record <- case o.recordFile of
    Nothing -> pure (const (pure ()))
    Just path -> do
      h <- openFile path AppendMode
      hSetBuffering h LineBuffering
      lock <- newMVar ()
      logLine ("recording every chat request to " <> T.pack path)
      pure \v -> withMVar lock \() -> BLC.hPutStrLn h (encode v)
  index <- forM o.index \i -> do
    conninfo <- setting i.indexDb "OPEN_SLOP_RAG_DB" (Just "dbname=llmq_rag")
    conn <- connectStore (T.pack conninfo)
    migrate conn >>= either dieWith pure
    embedAt <- setting i.indexEmbedAt "OPEN_SLOP_RAG_EMBED_AT" Nothing
    embedModel <- setting i.indexEmbedModel "OPEN_SLOP_RAG_EMBED_MODEL" Nothing
    chatAt <- setting i.indexChatAt "OPEN_SLOP_RAG_CHAT_AT" Nothing
    chatModel <- setting i.indexChatModel "OPEN_SLOP_RAG_CHAT_MODEL" Nothing
    rerankAt <- optionalSetting i.indexRerankAt "OPEN_SLOP_RAG_RERANK_AT"
    rerankModel <- optionalSetting i.indexRerankModel "OPEN_SLOP_RAG_RERANK_MODEL"
    client <- newClient
    let config = (defaultAskConfig (T.pack embedAt) (T.pack embedModel) (T.pack chatAt) (T.pack chatModel)) {rerankAt = T.pack <$> rerankAt, rerankModel = T.pack <$> rerankModel}
    a <- askingFrom client cat conn config logLine >>= either dieWith pure
    logLine ("serving the index from " <> T.pack conninfo <> ": answers by " <> T.pack chatAt <> "/" <> T.pack chatModel <> maybe ", no reranker" (\w -> ", reranked by " <> T.pack w) rerankAt)
    pure a
  asks <- traverse (`newAsks` logLine) index
  case (o.webDir, index) of
    (Just _, Nothing) -> dieWith "--web serves a page that asks the index, so it needs --index"
    _ -> pure ()
  env <- newEnv cat keys logLine Warp.pauseTimeout record index asks o.webDir
  logLine
    ( "serving " <> T.intercalate ", " (map endpointId cat.endpoints) <> " for " <> T.pack (show (keyCount keys)) <> " clients on "
        <> T.pack o.host <> ":" <> T.pack (show o.port) <> maybe " without TLS" (const " with TLS") tls
    )
  let settings = Warp.setHost (fromString o.host) (Warp.setPort o.port Warp.defaultSettings)
  case tls of
    Just (c, k) -> WarpTLS.runTLS (WarpTLS.tlsSettings c k) settings (app env)
    Nothing -> Warp.runSettings settings (app env)

logLine :: Text -> IO ()
logLine t = do
  now <- getCurrentTime
  TIO.hPutStrLn stderr (T.pack (iso8601Show now) <> " " <> t)

-- | A flag, else the variable, else the fallback, else an error naming
-- both.
setting :: Maybe String -> String -> Maybe String -> IO String
setting given var fallback = case given of
  Just v -> pure v
  Nothing ->
    lookupEnv var >>= \case
      Just v | not (null v) -> pure v
      _ -> maybe (dieWith ("--index needs " <> T.pack var <> " or its flag")) pure fallback

optionalSetting :: Maybe String -> String -> IO (Maybe String)
optionalSetting given var = case given of
  Just v -> pure (Just v)
  Nothing ->
    lookupEnv var >>= \case
      Just v | not (null v) -> pure (Just v)
      _ -> pure Nothing

dieWith :: Text -> IO a
dieWith t = TIO.hPutStrLn stderr ("open-slop-gateway: " <> t) >> exitFailure