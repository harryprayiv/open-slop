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
module Main (main) where

import Data.Aeson (eitherDecodeFileStrict)
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
import OpenSlop.Gateway.Server (app, newEnv)
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
  env <- newEnv cat keys logLine Warp.pauseTimeout
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

dieWith :: Text -> IO a
dieWith t = TIO.hPutStrLn stderr ("open-slop-gateway: " <> t) >> exitFailure
