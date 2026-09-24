-- | The gateway as a WAI application.
--
-- Routes:
--
--   GET  /healthz              200, no key needed; for a unit's readiness
--   GET  /v1/models            every model the backends report, as ids
--   POST /v1/chat/completions  one request, translated for its backend
--
-- Everything but /healthz needs a bearer key. Every refusal is an OpenAI
-- error body, so a client built on the openai bindings (Grace included)
-- surfaces the message rather than a decode failure.
--
-- The model listing is asked of the backends and cached for thirty
-- seconds: a request names a model by what the servers report, and asking
-- them on every request would add a round trip to each backend per call.
--
-- Nothing here orders or queues requests. Each backend already serves one
-- request at a time (ollama with OLLAMA_NUM_PARALLEL=1, llama-server with
-- one slot) and queues the rest itself; a second queue in front of it would
-- only hide the first one's position.
module OpenSlop.Gateway.Server
  ( Env (..)
  , newEnv
  , app
  ) where

import Control.Monad (forM)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (Header, Status, hContentType, mkStatus, status200)
import Network.Wai
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Gateway.Keys
import OpenSlop.Gateway.Route
import OpenSlop.Gateway.Translate
import OpenSlop.Http
import OpenSlop.OpenAI
import OpenSlop.Stats (Stats (..), Verdict (..), judge)

data Env = Env
  { catalogue :: Catalogue
  -- ^ its endpoints are the backends this gateway fronts, normally on
  -- loopback
  , keys :: Keys
  , client :: Client
  , listing :: IORef (Maybe (Double, Listing))
  , counter :: IORef Int
  , logLine :: Text -> IO ()
  , pause :: Request -> IO ()
  -- ^ called before a generation starts; warp's pauseTimeout, so a long
  -- prefill does not trip the server's idle timeout
  , maxBodyBytes :: Int
  }

newEnv :: Catalogue -> Keys -> (Text -> IO ()) -> (Request -> IO ()) -> IO Env
newEnv catalogue keys logLine pause = do
  client <- newClient
  listing <- newIORef Nothing
  counter <- newIORef 0
  pure Env {catalogue, keys, client, listing, counter, logLine, pause, maxBodyBytes = 8 * 1024 * 1024}

app :: Env -> Application
app env req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["healthz"]) -> respond (responseLBS status200 [(hContentType, "text/plain")] "ok\n")
    (method, path) -> case authorise env.keys (lookup "Authorization" (requestHeaders req)) of
      Left why -> do
        env.logLine ("refused " <> TE.decodeUtf8With TE.lenientDecode method <> " /" <> T.intercalate "/" path <> ": " <> why)
        respond (errorResponse (ApiError 401 "authentication_error" (Just "invalid_api_key") why))
      Right who -> case (method, path) of
        ("GET", ["v1", "models"]) -> modelList env >>= respond . jsonResponse status200
        ("POST", ["v1", "chat", "completions"]) -> chat env who req >>= respond
        _ -> respond (errorResponse (ApiError 404 "invalid_request_error" (Just "not_found") ("no route " <> TE.decodeUtf8With TE.lenientDecode method <> " /" <> T.intercalate "/" path)))

jsonResponse :: (ToJSON a) => Status -> a -> Response
jsonResponse s v = responseLBS s [(hContentType, "application/json")] (Aeson.encode v)

errorResponse :: ApiError -> Response
errorResponse e = jsonResponse (mkStatus e.status (TE.encodeUtf8 e.kind)) (apiErrorValue e)

-- | What the backends serve, from the cache when it is under thirty seconds
-- old. An endpoint that does not answer is left out and logged.
currentListing :: Env -> IO Listing
currentListing env = do
  now <- realToFrac <$> getPOSIXTime
  cached <- readIORef env.listing
  case cached of
    Just (at, l) | now - at < 30 -> pure l
    _ -> do
      l <- fmap catMaybes $ forM env.catalogue.endpoints \ep ->
        case (\b -> b.engine) <$> Map.lookup ep.backend env.catalogue.backends of
          Nothing -> do
            env.logLine ("endpoint " <> endpointId ep <> " names backend " <> ep.backend <> ", which the catalogue does not have")
            pure Nothing
          Just engine -> do
            r <- getBody env.client NoAuth (ep.url <> TE.decodeUtf8 (tagsPath engine)) 8
            case r >>= maybe (Left (Transport "unreadable model listing")) Right . parseTags engine of
              Left f -> do
                env.logLine ("endpoint " <> endpointId ep <> " at " <> ep.url <> ": " <> describeFailure f)
                pure Nothing
              Right served -> pure (Just (ep, map (\m -> m.name) served))
      writeIORef env.listing (Just (now, l))
      pure l

modelList :: Env -> IO Value
modelList env = do
  l <- currentListing env
  pure
    ( object
        [ "object" .= ("list" :: Text)
        , "data"
            .= [ object
                   [ "id" .= (endpointId ep <> "/" <> n)
                   , "object" .= ("model" :: Text)
                   , "created" .= (0 :: Int)
                   , "owned_by" .= ep.row
                   ]
               | (ep, names) <- l
               , n <- names
               ]
        ]
    )

chat :: Env -> Text -> Request -> IO Response
chat env who req = do
  raw <- strictRequestBody req
  if BL.length raw > fromIntegral env.maxBodyBytes
    then pure (errorResponse (ApiError 413 "invalid_request_error" (Just "request_too_large") ("the body is over " <> tshow env.maxBodyBytes <> " bytes")))
    else case Aeson.eitherDecode raw of
      -- aeson prefixes "Error in $: "; the JSON path after "in" is kept
      -- when it points inside the body, since it names the bad field.
      Left e -> reject (invalidRequest Nothing (T.replace "Error in $: " "" (T.pack e)))
      Right (r :: ChatRequest) -> do
        l <- currentListing env
        case resolveTarget env.catalogue l r.model of
          Left why -> reject (ApiError 404 "invalid_request_error" (Just "model_not_found") why)
          Right t -> case plan t r of
            Left e -> reject e
            Right c -> run t r c
  where
    reject e = do
      env.logLine (who <> " refused: " <> e.message)
      pure (errorResponse e)
    run t r c = do
      env.pause req
      t0 <- getPOSIXTime
      res <- postJsonWithin Nothing env.client NoAuth t.endpoint.url c.path c.body
      t1 <- getPOSIXTime
      let wall = floor (t1 - t0) :: Int
          inputBytes = sum [BC.length (TE.encodeUtf8 m.content) | m <- r.messages]
          constrained = case r.responseFormat of
            Just FormatJsonSchema {} -> True
            Just FormatJsonObject -> True
            _ -> False
      case res of
        Left (Transport why) -> failed wall (ApiError 502 "api_error" (Just "backend_unreachable") (targetId t <> ": " <> why))
        Left (Status code body)
          | code >= 500 -> failed wall (ApiError 502 "api_error" (Just "backend_error") (targetId t <> " answered " <> tshow code <> ": " <> TE.decodeUtf8With TE.lenientDecode body))
          | otherwise -> failed wall (invalidRequest (Just "backend_rejected") (targetId t <> " answered " <> tshow code <> ": " <> TE.decodeUtf8With TE.lenientDecode body))
        Right body -> case parseBackendReply t.backend.engine body of
          Left why -> failed wall (ApiError 502 "api_error" (Just "backend_error") (targetId t <> ": " <> why))
          -- A schema-constrained answer that stopped at the token cap is
          -- incomplete JSON by construction: the grammar was still inside
          -- a string or an object when the budget ran out. Returning it
          -- 200 leaves the client with a decode error and no cause, so it
          -- is a refusal here, naming the cap. Measured on a 0.5B, which
          -- repeated one sentence until it hit 2048 tokens.
          Right reply
            | constrained && reply.finish == FinishLength ->
                failed
                  wall
                  ( invalidRequest
                      (Just "length_before_schema_complete")
                      ( targetId t <> " stopped at its " <> tshow c.predict
                          <> "-token output cap with the schema unfinished, so the answer is not valid JSON. Send fewer input bytes, raise max_completion_tokens, or use a model that does not repeat itself."
                      )
                  )
          Right reply -> case judge (withPredict c.predict t.budget) 0 inputBytes wall (finalInfo reply) of
            Truncated why -> failed wall (invalidRequest (Just "context_length_exceeded") (targetId t <> ": " <> why))
            Kept st -> do
              n <- atomicModifyIORef' env.counter (\i -> (i + 1, i + 1))
              let estimated = not (isJust reply.promptTokens)
                  promptTokens = fromMaybe (ceiling (fromIntegral inputBytes / t.budget.bytesPerToken :: Double)) reply.promptTokens
                  completionTokens = fromMaybe 0 reply.completionTokens
                  resp =
                    ChatResponse
                      { responseId = "chatcmpl-open-slop-" <> tshow (floor t0 :: Int) <> "-" <> tshow n
                      , created = floor t0
                      , model = targetId t
                      , content = reply.content
                      , finish = reply.finish
                      , usage = Usage {promptTokens, completionTokens}
                      }
                  headers :: [Header]
                  headers =
                    [(hContentType, "application/json")]
                      <> [("X-Open-Slop-Prompt-Tokens", "estimated") | estimated]
                      <> [("X-Open-Slop-Warnings", TE.encodeUtf8 (T.intercalate "; " st.warnings)) | not (null st.warnings)]
              env.logLine
                ( who <> " " <> targetId t <> " ok in " <> tshow wall <> "s: "
                    <> tshow promptTokens <> (if estimated then "~" else "") <> " prompt, "
                    <> tshow completionTokens <> " completion"
                    <> maybe "" (\g -> ", " <> tshow g <> " tok/s") st.genTokPerSec
                    <> (if null st.warnings then "" else "; " <> T.intercalate "; " st.warnings)
                )
              pure (responseLBS status200 headers (Aeson.encode resp))
      where
        failed wall e = do
          env.logLine (who <> " " <> targetId t <> " failed after " <> tshow wall <> "s: " <> e.message)
          pure (errorResponse e)

-- | The budget with the output cap this request actually sent, so the
-- verdict's warnings are about this request and not the catalogue default.
withPredict :: Int -> Budget -> Budget
withPredict p b =
  Budget {ctx = b.ctx, predict = p, chunkBytes = b.chunkBytes, bytesPerToken = b.bytesPerToken, temperature = b.temperature}

tshow :: (Show a) => a -> Text
tshow = T.pack . show