-- | The gateway as a WAI application.
--
-- Routes:
--
--   GET  /healthz              200, no key needed; for a unit's readiness
--   GET  /v1/models            every model the backends report, as ids
--   POST /v1/chat/completions  one request, translated for its backend
--
-- ============================================================================
-- THE INDEX AS A MODEL
-- ============================================================================
--
-- With an index configured (open-slop-gateway --index), llmq-index's
-- database is served as models of its own: `index` asks the whole index,
-- and `index/NAME` asks only the root whose last path component is NAME
-- (index/cheeblr for ~/ingest/cheeblr). Both are listed by /v1/models. A
-- request to one is answered by "OpenSlop.Rag.Ask", the same search,
-- reranking, margin and packing as llmq-index ask, so what its evaluation
-- sets measured holds here.
--
-- The question is the last user message. Earlier user and assistant
-- messages are the conversation, and the question is rewritten against
-- them before searching, as in llmq-index chat. System messages are left
-- out: the index sends its own instructions and its own answer schema,
-- and a client's instructions (Grace sends its type as system messages)
-- would only compete with them.
--
-- With a JSON response format the reply's content is the cited answer as
-- JSON, { parts, sources }: each part with what it asks, its claims and the
-- numbers of the sources each rests on, and its gap; each source with its
-- number, path, lines, heading and whether a claim cited it. That is the
-- type stages/index/ask.ffg declares, so a Grace program asks the index the
-- way it asks a model and gets the answer at a type. Without a response
-- format the content is the answer as text, claim by claim with source
-- numbers, then the sources.
--
-- The client's schema is not sent to the model. The index's own schema is
-- stricter than anything Grace can express (every part answered or
-- explained, every source number one that was sent), and that is the one
-- the model is held to.
--
-- ============================================================================
-- THE WEB PAGE
-- ============================================================================
--
-- With --web DIR the gateway also serves the page built from open-slop's
-- web/ directory: GET / is DIR/index.html and GET /NAME is DIR/NAME, for a
-- single path segment with no slashes, so the page and the API it calls
-- share an origin and need no cross-origin rules. The page holds nothing
-- but code; it asks for the key and sends it on every call.
--
-- The page asks the index through these, which need the key like
-- everything else and are served only with an index:
--
--   GET  /index/models          ["index", "index/NAME", ...]
--   GET  /index/sessions        the stored conversations
--   GET  /index/sessions/NAME   one conversation's turns, each assistant
--                               turn with its cited answer when the
--                               gateway stored one
--   POST /index/asks            {session, model, question} -> 202 {id}
--   GET  /index/asks/ID         where that job is; see
--                               "OpenSlop.Gateway.Asks"
--
-- Everything but /healthz and the page needs a bearer key. Every refusal
-- is an OpenAI error body, so a client built on the openai bindings (Grace included)
-- surfaces the message rather than a decode failure.
--
-- The model listing is asked of the backends and cached for thirty
-- seconds: a request names a model by what the servers report, and asking
-- them on every request would add a round trip to each backend per call.
--
-- With a record sink (open-slop-gateway's --record), every chat request
-- is also written as one JSON object: who asked, for which model, whether
-- a schema constrained it, how many messages and bytes it carried, whether
-- it was a repair (a message labelled Error, which is how Grace sends a
-- failed attempt back), the prompt and completion tokens, the seconds, and
-- how it ended. That is what llmq-grace --measure joins its runs against,
-- because a Grace program's calls are not visible from outside it any
-- other way: Grace does not return the usage, and an import prompt makes
-- as many calls as its repairs need.
--
-- Requests to /v1/chat/completions are not ordered or queued here. Each
-- backend already serves one request at a time (ollama with
-- OLLAMA_NUM_PARALLEL=1, llama-server with one slot) and queues the rest
-- itself; a second queue in front of it would only hide the first one's
-- position. The page's index jobs are the exception and run one at a time
-- in their own queue, which can report a position; "OpenSlop.Gateway.Asks"
-- says why.
module OpenSlop.Gateway.Server
  ( Env (..)
  , newEnv
  , app
  ) where

import Control.Monad (forM)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Network.HTTP.Types (Header, Status, hContentType, mkStatus, status200)
import Network.Wai
import OpenSlop.Catalogue
import OpenSlop.Engine (ServedModel (..), parseTags, tagsPath)
import OpenSlop.Gateway.Keys
import OpenSlop.Gateway.Route
import OpenSlop.Gateway.Translate
import OpenSlop.Http
import OpenSlop.OpenAI
import OpenSlop.Gateway.Asks (Asks, answerValue, indexModels, jobStatus, scopeOf, submit, unanswered)
import OpenSlop.Rag.Ask (Asking (..), Selection (..), answerWith, select)
import OpenSlop.Rag.Retrieve (Answer (..))
import OpenSlop.Rag.Store (Hit (..), SessionInfo (..), findSession, listSessions, sessionTurnsStored)
import OpenSlop.Stats (Stats (..), Verdict (..), judge)
import System.Directory (doesFileExist)
import System.FilePath (takeExtension, (</>))
import Text.Read (readMaybe)

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
  , record :: Value -> IO ()
  -- ^ one object per chat request; see the module header
  , index :: Maybe Asking
  -- ^ llmq-index's database, served as the models index and index/NAME;
  -- see the module header
  , asks :: Maybe Asks
  -- ^ the index's job queue, for the web page; present with an index
  , web :: Maybe FilePath
  -- ^ the built web page's directory
  }

newEnv :: Catalogue -> Keys -> (Text -> IO ()) -> (Request -> IO ()) -> (Value -> IO ()) -> Maybe Asking -> Maybe Asks -> Maybe FilePath -> IO Env
newEnv catalogue keys logLine pause record index asks web = do
  client <- newClient
  listing <- newIORef Nothing
  counter <- newIORef 0
  pure Env {catalogue, keys, client, listing, counter, logLine, pause, maxBodyBytes = 8 * 1024 * 1024, record, index, asks, web}

app :: Env -> Application
app env req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", ["healthz"]) -> respond (responseLBS status200 [(hContentType, "text/plain")] "ok\n")
    ("GET", []) | Just dir <- env.web -> page dir "index.html" >>= respond
    ("GET", [file]) | Just dir <- env.web, servable file -> page dir file >>= respond
    (method, path) -> case authorise env.keys (lookup "Authorization" (requestHeaders req)) of
      Left why -> do
        env.logLine ("refused " <> TE.decodeUtf8With TE.lenientDecode method <> " /" <> T.intercalate "/" path <> ": " <> why)
        respond (errorResponse (ApiError 401 "authentication_error" (Just "invalid_api_key") why))
      Right who -> case (method, path) of
        ("GET", ["v1", "models"]) -> modelList env >>= respond . jsonResponse status200
        ("POST", ["v1", "chat", "completions"]) -> chat env who req >>= respond
        (_, "index" : rest) | Just a <- env.index, Just q <- env.asks -> indexRoute env a q method rest req >>= respond
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
  names <- maybe (pure []) indexModels env.index
  pure
    ( object
        [ "object" .= ("list" :: Text)
        , "data"
            .= ( [ object
                   [ "id" .= (endpointId ep <> "/" <> n)
                   , "object" .= ("model" :: Text)
                   , "created" .= (0 :: Int)
                   , "owned_by" .= ep.row
                   ]
               | (ep, served) <- l
               , n <- served
               ]
              <> [ object ["id" .= n, "object" .= ("model" :: Text), "created" .= (0 :: Int), "owned_by" .= ("llmq-index" :: Text)]
                 | n <- names
                 ]
               )
        ]
    )

chat :: Env -> Text -> Request -> IO Response
chat env who req = do
  started <- getPOSIXTime
  raw <- strictRequestBody req
  if BL.length raw > fromIntegral env.maxBodyBytes
    then pure (errorResponse (ApiError 413 "invalid_request_error" (Just "request_too_large") ("the body is over " <> tshow env.maxBodyBytes <> " bytes")))
    else case Aeson.eitherDecode raw of
      -- aeson prefixes "Error in $: "; the JSON path after "in" is kept
      -- when it points inside the body, since it names the bad field.
      Left e -> reject started Nothing Nothing (invalidRequest Nothing (T.replace "Error in $: " "" (T.pack e)))
      Right (r :: ChatRequest)
        | Just a <- env.index
        , r.model == "index" || "index/" `T.isPrefixOf` r.model ->
            askIndex started a r
      Right (r :: ChatRequest) -> do
        l <- currentListing env
        case resolveTarget env.catalogue l r.model of
          Left why -> reject started (Just r) Nothing (ApiError 404 "invalid_request_error" (Just "model_not_found") why)
          Right t -> case plan t r of
            Left e -> reject started (Just r) (Just t) e
            Right c -> run started t r c
  where
    reject started r t e = do
      env.logLine (who <> " refused: " <> e.message)
      ended <- getPOSIXTime
      env.record (requestRecord who started ended r t Nothing (Left e))
      pure (errorResponse e)
    askIndex started a r = do
      scopeFor <- scopeOf a r.model
      let turns = [(if m.role == RoleAssistant then "assistant" else "user", m.content) | m <- r.messages, m.role /= RoleSystem]
      case (scopeFor, reverse turns) of
        (Left why, _) -> reject started (Just r) Nothing (ApiError 404 "invalid_request_error" (Just "model_not_found") why)
        (_, []) -> reject started (Just r) Nothing (invalidRequest Nothing "a question to the index is the last user message, and there is none")
        (_, (role, _) : _) | role /= "user" -> reject started (Just r) Nothing (invalidRequest Nothing "a question to the index is the last user message; this conversation ends with an assistant turn")
        (Right sc, (_, question) : earlier) -> do
          env.pause req
          scopeRef <- newIORef sc
          let one = a {scope = scopeRef, note = \t -> env.logLine (who <> " " <> r.model <> ": " <> t)}
              history = reverse earlier
          t0 <- getPOSIXTime
          picked <- select one history question
          answered <- case picked of
            -- Nothing in scope matches: an answer with one unanswered part,
            -- so a client gets the same shape whatever the index holds.
            -- select says so in words beginning "nothing"; every other
            -- Left is a server failing (the embedder, the reranker, the
            -- chat model rewriting a follow-up) and stays an error, so an
            -- outage is never returned as an answer that the sources are
            -- silent.
            Left why | "nothing " `T.isPrefixOf` why -> pure (Right (Left why))
            Left e -> pure (Left e)
            Right sel -> fmap Right <$> answerWith one history question sel.packed (const (pure ()))
          t1 <- getPOSIXTime
          case answered of
            Left e -> do
              env.logLine (who <> " " <> r.model <> " failed: " <> e)
              env.record (requestRecord who started t1 (Just r) Nothing (Just (t1 - t0)) (Left (ApiError 502 "api_error" (Just "backend_error") e)))
              pure (errorResponse (ApiError 502 "api_error" (Just "backend_error") (r.model <> ": " <> e)))
            Right got -> do
              n <- atomicModifyIORef' env.counter (\i -> (i + 1, i + 1))
              let asJson = case r.responseFormat of
                    Just FormatJsonSchema {} -> True
                    Just FormatJsonObject -> True
                    _ -> False
                  content = case got of
                    Left why -> if asJson then TE.decodeUtf8 (BL.toStrict (Aeson.encode (unanswered question why))) else "Not in the sources: " <> why
                    Right ans -> if asJson then TE.decodeUtf8 (BL.toStrict (Aeson.encode (answerValue ans))) else answerText ans
                  promptTokens = either (const 0) (\ans -> fromMaybe 0 ans.promptTokens) got
                  resp =
                    ChatResponse
                      { responseId = "chatcmpl-open-slop-" <> tshow (floor t0 :: Int) <> "-" <> tshow n
                      , created = floor t0
                      , model = r.model
                      , content
                      , finish = FinishStop
                      , usage = Usage {promptTokens, completionTokens = 0}
                      }
              env.logLine (who <> " " <> r.model <> " answered in " <> tshow (floor (t1 - t0) :: Int) <> "s from " <> tshow (either (const 0) (\ans -> length ans.sources) got) <> " sources")
              env.record (requestRecord who started t1 (Just r) Nothing (Just (t1 - t0)) (Right (promptTokens, False, 0, FinishStop)))
              pure (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode resp))
    run started t r c = do
      env.pause req
      t0 <- getPOSIXTime
      res <- postJsonWithin Nothing env.client NoAuth t.endpoint.url c.path c.body
      t1 <- getPOSIXTime
      let note outcome = env.record (requestRecord who started t1 (Just r) (Just t) (Just (t1 - t0)) outcome)
          failed wall e = do
            env.logLine (who <> " " <> targetId t <> " failed after " <> tshow wall <> "s: " <> e.message)
            note (Left e)
            pure (errorResponse e)
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
              note (Right (promptTokens, estimated, completionTokens, reply.finish))
              pure (responseLBS status200 headers (Aeson.encode resp))

-- | The answer as text: the rendered claims with their source numbers,
-- then the sources, the cited ones marked.
answerText :: Answer -> Text
answerText ans =
  ans.text
    <> "\n\nSources:\n"
    <> T.intercalate
      "\n"
      [ (if k `elem` ans.cited then "* [" else "  [") <> tshow k <> "] " <> h.path <> ":" <> tshow h.lineFrom <> "-" <> tshow h.lineTo
      | (k, h) <- zip [1 :: Int ..] ans.sources
      ]

-- | One request as the record sink writes it. Times are seconds since the
-- epoch, with fractions. A repair is a request with a message whose first line is the
-- label Error, which is how Grace returns a failed attempt and the
-- complaint about it; the gateway writes a message's name at the top of
-- its content, so the label is there whichever way the client sent it.
requestRecord
  :: Text
  -> POSIXTime
  -> POSIXTime
  -> Maybe ChatRequest
  -> Maybe Target
  -> Maybe POSIXTime
  -> Either ApiError (Int, Bool, Int, FinishReason)
  -> Value
requestRecord who started ended r t backendSeconds outcome =
  object
    ( [ "at" .= (realToFrac started :: Double)
      , "seconds" .= (realToFrac (ended - started) :: Double)
      , "client" .= who
      ]
        <> maybe
          []
          ( \x ->
              [ "model" .= x.model
              , "schema" .= case x.responseFormat of
                  Just FormatJsonSchema {} -> True
                  Just FormatJsonObject -> True
                  _ -> False
              , "messages" .= length x.messages
              , "inputBytes" .= sum [BC.length (TE.encodeUtf8 m.content) | m <- x.messages]
              , "repair" .= any (\m -> "Error:" `T.isPrefixOf` T.stripStart m.content) x.messages
              ]
          )
          r
        <> maybe [] (\x -> ["target" .= targetId x, "engine" .= engineName x.backend.engine]) t
        <> maybe [] (\b -> ["backendSeconds" .= (realToFrac b :: Double)]) backendSeconds
        <> case outcome of
          Left e -> ["outcome" .= fromMaybe e.kind e.code, "message" .= e.message]
          Right (p, est, c, fin) ->
            [ "outcome" .= ("ok" :: Text)
            , "promptTokens" .= p
            , "promptEstimated" .= est
            , "completionTokens" .= c
            , "finish" .= tshow fin
            ]
    )

-- | The page's routes under /index; see the module header.
indexRoute :: Env -> Asking -> Asks -> BC.ByteString -> [Text] -> Request -> IO Response
indexRoute env a q method rest req = case (method, rest) of
  ("GET", ["models"]) -> jsonResponse status200 <$> indexModels a
  ("GET", ["sessions"]) -> do
    ss <- listSessions a.conn
    pure (jsonResponse status200 [object ["name" .= s.name, "turns" .= s.turns, "created" .= s.created] | s <- ss])
  ("GET", ["sessions", name]) ->
    findSession a.conn name >>= \case
      Nothing -> pure (jsonResponse status200 (object ["name" .= name, "turns" .= ([] :: [Value])]))
      Just sid -> do
        ts <- sessionTurnsStored a.conn sid
        pure
          ( jsonResponse
              status200
              ( object
                  [ "name" .= name
                  , "turns"
                      .= [ object (["role" .= role, "text" .= text] <> ["answer" .= v | Just v@(Aeson.Object o) <- [stored], KeyMap.member "parts" o])
                         | (role, text, stored) <- ts
                         ]
                  ]
              )
          )
  ("POST", ["asks"]) -> do
    raw <- strictRequestBody req
    if BL.length raw > 65536
      then pure (errorResponse (ApiError 413 "invalid_request_error" (Just "request_too_large") "a question is at most 64 KB"))
      else case Aeson.decode raw of
        Just (Aeson.Object o)
          | Just (Aeson.String s) <- KeyMap.lookup "session" o
          , Just (Aeson.String m) <- KeyMap.lookup "model" o
          , Just (Aeson.String qn) <- KeyMap.lookup "question" o ->
              submit q s m qn >>= \case
                Left why -> pure (errorResponse (invalidRequest Nothing why))
                Right i -> pure (jsonResponse (mkStatus 202 "Accepted") (object ["id" .= i]))
        _ -> pure (errorResponse (invalidRequest Nothing "send {\"session\": TEXT, \"model\": TEXT, \"question\": TEXT}"))
  ("GET", ["asks", n]) | Just i <- readMaybe (T.unpack n) ->
    jobStatus q i >>= \case
      Just v -> pure (jsonResponse status200 v)
      Nothing -> pure (errorResponse (ApiError 404 "invalid_request_error" (Just "not_found") ("no job " <> n <> "; it was never submitted, or ended more than an hour ago")))
  _ -> do
    env.logLine ("no index route " <> TE.decodeUtf8With TE.lenientDecode method <> " /index/" <> T.intercalate "/" rest)
    pure (errorResponse (ApiError 404 "invalid_request_error" (Just "not_found") ("no route /index/" <> T.intercalate "/" rest)))

-- | A file of the built page: one path segment, no hidden files, no
-- separators, so nothing outside the directory can be named.
servable :: Text -> Bool
servable f = not (T.null f) && not ("." `T.isPrefixOf` f) && T.all (\c -> c /= '/' && c /= '\\') f

page :: FilePath -> Text -> IO Response
page dir file = do
  let path = dir </> T.unpack file
  exists <- doesFileExist path
  if exists
    then pure (responseFile status200 [(hContentType, contentType (takeExtension path)), ("Cache-Control", "no-cache")] path Nothing)
    else pure (responseLBS (mkStatus 404 "Not Found") [(hContentType, "text/plain")] "not found\n")
  where
    contentType = \case
      ".html" -> "text/html; charset=utf-8"
      ".js" -> "text/javascript; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      ".svg" -> "image/svg+xml"
      ".map" -> "application/json"
      _ -> "application/octet-stream"

-- | The budget with the output cap this request actually sent, so the
-- verdict's warnings are about this request and not the catalogue default.
withPredict :: Int -> Budget -> Budget
withPredict p b =
  Budget {ctx = b.ctx, predict = p, chunkBytes = b.chunkBytes, bytesPerToken = b.bytesPerToken, temperature = b.temperature}

tshow :: (Show a) => a -> Text
tshow = T.pack . show