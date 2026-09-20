-- | HTTP to an inference server: a probe, and a request whose response
-- lines are handed to a callback as they arrive.
--
-- One shared TLS-capable manager, with no response timeout of its own: a
-- CPU prefill can be silent for many minutes and the caller's own ceiling
-- decides when that becomes a failure. The connection has keepalive, which
-- is what tells a dead server apart from a slow one.
module OpenSlop.Http
  ( Client
  , newClient
  , Auth (..)
  , getBody
  , postLines
  , postJson
  , HttpFailure (..)
  , describeFailure
  ) where

import Control.Exception (Exception, try)
import Data.Aeson (ToJSON, encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)

newtype Client = Client Manager

data Auth = NoAuth | Bearer Text

data HttpFailure
  = Transport Text
  | Status Int ByteString
  -- ^ non-2xx, with the first 300 bytes of the body
  deriving stock (Show)
  deriving anyclass (Exception)

describeFailure :: HttpFailure -> Text
describeFailure = \case
  Transport t -> "transport: " <> t
  Status code body -> "HTTP " <> T.pack (show code) <> ": " <> TE.decodeUtf8With TE.lenientDecode body

newClient :: IO Client
newClient =
  Client
    <$> newTlsManagerWith
      tlsManagerSettings
        { managerResponseTimeout = responseTimeoutNone
        }

authHeader :: Auth -> [Header]
authHeader = \case
  NoAuth -> []
  Bearer t -> [("Authorization", "Bearer " <> TE.encodeUtf8 t)]

-- | GET with a total ceiling in seconds, for probes.
getBody :: Client -> Auth -> Text -> Int -> IO (Either HttpFailure BL.ByteString)
getBody (Client mgr) auth url maxSeconds = do
  r <- try @HttpException do
    req0 <- parseRequest (T.unpack url)
    let req =
          req0
            { requestHeaders = authHeader auth
            , responseTimeout = responseTimeoutMicro (maxSeconds * 1000000)
            }
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), responseBody resp)
  pure case r of
    Left e -> Left (Transport (describeException e))
    Right (code, body)
      | code >= 200 && code < 300 -> Right body
      | otherwise -> Left (Status code (BL.toStrict (BL.take 300 body)))

-- | POST a JSON body to @base <> path@ and hand each response line to the
-- callback as it arrives. Lines are split on newline; a trailing partial
-- line is delivered at the end. A non-2xx answer is returned as a failure
-- carrying the start of the body, and no lines are delivered for it.
postLines
  :: (ToJSON a)
  => Client
  -> Auth
  -> Text
  -> ByteString
  -> a
  -> (ByteString -> IO ())
  -> IO (Either HttpFailure ())
postLines (Client mgr) auth base path body onLine = do
  r <- try @HttpException do
    req0 <- parseRequest (T.unpack base)
    let req =
          req0
            { method = "POST"
            , path = path
            , requestHeaders = ("Content-Type", "application/json") : authHeader auth
            , requestBody = RequestBodyLBS (encode body)
            }
    withResponse req mgr \resp -> do
      let code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then Right <$> readLines (responseBody resp) onLine
        else do
          chunks <- brConsume (responseBody resp)
          pure (Left (Status code (B.take 300 (B.concat chunks))))
  pure case r of
    Left e -> Left (Transport (describeException e))
    Right x -> x

-- | POST a JSON body and return the whole response body. For small
-- request-reply routes such as llama-server's /apply-template.
postJson
  :: (ToJSON a)
  => Client
  -> Auth
  -> Text
  -> ByteString
  -> a
  -> IO (Either HttpFailure BL.ByteString)
postJson (Client mgr) auth base path body = do
  r <- try @HttpException do
    req0 <- parseRequest (T.unpack base)
    let req =
          req0
            { method = "POST"
            , path = path
            , requestHeaders = ("Content-Type", "application/json") : authHeader auth
            , requestBody = RequestBodyLBS (encode body)
            , responseTimeout = responseTimeoutMicro (60 * 1000000)
            }
    resp <- httpLbs req mgr
    pure (statusCode (responseStatus resp), responseBody resp)
  pure case r of
    Left e -> Left (Transport (describeException e))
    Right (code, b)
      | code >= 200 && code < 300 -> Right b
      | otherwise -> Left (Status code (BL.toStrict (BL.take 300 b)))

-- | One line, without the request dump http-client's Show instance includes.
describeException :: HttpException -> Text
describeException = \case
  HttpExceptionRequest _ content -> case content of
    ConnectionFailure e -> "connection failed: " <> firstLine (show e)
    ConnectionTimeout -> "connection timed out"
    ResponseTimeout -> "no response within the timeout"
    ResponseBodyTooShort a b -> "response ended early (" <> T.pack (show b) <> " of " <> T.pack (show a) <> " bytes)"
    other -> firstLine (show other)
  InvalidUrlException u why -> "invalid URL " <> T.pack u <> ": " <> T.pack why
  where
    firstLine = T.pack . takeWhile (/= '\n')

readLines :: BodyReader -> (ByteString -> IO ()) -> IO ()
readLines reader onLine = go B.empty
  where
    go pending = do
      c <- brRead reader
      if B.null c
        then do
          let final = BC.strip pending
          if B.null final then pure () else onLine final
        else do
          let (complete, rest) = splitLines (pending <> c)
          mapM_ onLine [l | l <- complete, not (B.null (BC.strip l))]
          go rest
    splitLines s = case BC.elemIndexEnd '\n' s of
      Nothing -> ([], s)
      Just i -> (BC.lines (B.take i s), B.drop (i + 1) s)