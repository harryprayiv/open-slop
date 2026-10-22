-- | The gateway's /index routes, as typed calls.
-- |
-- | Every type here is the JSON open-slop-gateway sends; see
-- | OpenSlop.Gateway.Asks and OpenSlop.Gateway.Server in the Haskell
-- | library. A reply that does not decode is an error naming the field, so
-- | a change on one side that the other has not followed shows up as a
-- | message on the page rather than as a blank answer.
module Api
  ( Key(..)
  , Source
  , Claim
  , Part
  , Answer
  , Turn
  , SessionSummary
  , Phase(..)
  , Job
  , models
  , sessions
  , session
  , submit
  , job
  ) where

import Prelude

import Affjax (defaultRequest, printError)
import Affjax.RequestBody as RequestBody
import Affjax.RequestHeader (RequestHeader(..))
import Affjax.ResponseFormat as ResponseFormat
import Affjax.StatusCode (StatusCode(..))
import Affjax.Web as AX
import Data.Argonaut.Core (Json)
import Data.Argonaut.Decode (decodeJson, printJsonDecodeError, (.:))
import Data.Argonaut.Decode.Error (JsonDecodeError(..))
import Data.Argonaut.Encode (encodeJson)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.HTTP.Method (Method(..))
import Data.Maybe (Maybe(..))
import Effect.Aff (Aff)
import Foreign.Object (Object)

-- | The gateway key, sent as a bearer token on every call.
newtype Key = Key String

type Source =
  { number :: Int
  , path :: String
  , lineFrom :: Int
  , lineTo :: Int
  , heading :: String
  , cited :: Boolean
  }

type Claim = { claim :: String, sources :: Array Int }

-- | One thing the question asks: the claims that answer it, each with the
-- | numbers of the sources it rests on, and what the sources do not say.
type Part = { ask :: String, claims :: Array Claim, gap :: String }

type Answer = { parts :: Array Part, sources :: Array Source }

-- | A stored turn. An assistant turn the gateway answered carries its
-- | cited answer; one written by llmq-index chat at the terminal has only
-- | its text.
type Turn = { role :: String, text :: String, answer :: Maybe Answer }

type SessionSummary = { name :: String, turns :: Int }

-- | Where a question is. Queued counts the questions ahead of it, the one
-- | being answered included. Answering counts the characters of the
-- | answer received so far.
data Phase
  = Queued Int
  | Searching
  | Answering Int
  | Done Answer
  | Failed String

type Job = { id :: Int, seconds :: Number, phase :: Phase }

models :: Key -> Aff (Either String (Array String))
models k = decoded decodeJson <$> call k GET "/index/models" Nothing

sessions :: Key -> Aff (Either String (Array SessionSummary))
sessions k = decoded decodeJson <$> call k GET "/index/sessions" Nothing

-- | A session's turns. The name is checked by the page to be letters,
-- | digits, - and _, so it needs no escaping in the path.
session :: Key -> String -> Aff (Either String (Array Turn))
session k name = decoded turns <$> call k GET ("/index/sessions/" <> name) Nothing
  where
  turns j = do
    o <- (decodeJson j :: Either JsonDecodeError (Object Json))
    o .: "turns"

-- | Queue a question; the job's id.
submit :: Key -> { session :: String, model :: String, question :: String } -> Aff (Either String Int)
submit k body = decoded jobId <$> call k POST "/index/asks" (Just (encodeJson body))
  where
  jobId j = do
    o <- (decodeJson j :: Either JsonDecodeError (Object Json))
    o .: "id"

job :: Key -> Int -> Aff (Either String Job)
job k i = decoded decodeJob <$> call k GET ("/index/asks/" <> show i) Nothing

decodeJob :: Json -> Either JsonDecodeError Job
decodeJob j = do
  o <- (decodeJson j :: Either JsonDecodeError (Object Json))
  i <- o .: "id"
  seconds <- o .: "seconds"
  p <- (o .: "phase" :: Either JsonDecodeError (Object Json))
  tag <- (p .: "tag" :: Either JsonDecodeError String)
  phase <- case tag of
    "queued" -> Queued <$> p .: "ahead"
    "searching" -> pure Searching
    "answering" -> Answering <$> p .: "characters"
    "done" -> Done <$> p .: "answer"
    "failed" -> Failed <$> p .: "reason"
    other -> Left (TypeMismatch ("a job phase, not " <> other))
  pure { id: i, seconds, phase }

decoded :: forall a. (Json -> Either JsonDecodeError a) -> Either String Json -> Either String a
decoded f r = r >>= (lmap printJsonDecodeError <<< f)

-- | One call. A refusal from the gateway is an OpenAI error body, whose
-- | message is returned; anything else unexpected is described by status.
call :: Key -> Method -> String -> Maybe Json -> Aff (Either String Json)
call (Key k) method url body = do
  r <- AX.request
    ( defaultRequest
        { url = url
        , method = Left method
        , headers = [ RequestHeader "Authorization" ("Bearer " <> k) ]
        , content = RequestBody.json <$> body
        , responseFormat = ResponseFormat.json
        }
    )
  pure $ case r of
    Left e -> Left (printError e)
    Right res
      | res.status == StatusCode 200 || res.status == StatusCode 202 -> Right res.body
      | otherwise -> Left (refusal res.status res.body)

refusal :: StatusCode -> Json -> String
refusal (StatusCode n) j = case message of
  Right m -> m
  Left _ -> "the gateway answered HTTP " <> show n
  where
  message = do
    o <- (decodeJson j :: Either JsonDecodeError (Object Json))
    e <- (o .: "error" :: Either JsonDecodeError (Object Json))
    e .: "message"
