-- | The page: pick what to ask (the whole index or one root) and a
-- | conversation, ask, and read the answer claim by claim with its sources.
-- |
-- | A question is a job on the gateway (OpenSlop.Gateway.Asks). The page
-- | submits it, then asks after it every two seconds and shows where it
-- | is, until it is done; the answer is then read back from the stored
-- | conversation, so what the page shows after an answer is what a later
-- | visit, or `llmq-index chat --session NAME`, will find. Closing the tab
-- | loses nothing but the progress display.
-- |
-- | The key is kept in sessionStorage, which the browser clears when the
-- | tab closes, so it is not left on disk.
module Main (main) where

import Prelude

import Api (Answer, Job, Key(..), Part, Phase(..), Source, Turn)
import Api as Api
import Data.Array (elem, head, null)
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Int (floor)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (joinWith, trim)
import Effect (Effect)
import Effect.Aff (Milliseconds(..), delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Web.HTML (window)
import Web.HTML.Window (sessionStorage)
import Web.Storage.Storage (getItem, removeItem, setItem)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  void (runUI component unit body)

type State =
  { key :: Maybe Key
  , keyInput :: String
  , models :: Array String
  , model :: String
  , sessions :: Array String
  , session :: String
  , newSession :: String
  , turns :: Array Turn
  , question :: String
  , job :: Maybe Job
  , error :: Maybe String
  }

initial :: State
initial =
  { key: Nothing
  , keyInput: ""
  , models: []
  , model: "index"
  , sessions: []
  , session: ""
  , newSession: ""
  , turns: []
  , question: ""
  , job: Nothing
  , error: Nothing
  }

data Action
  = Init
  | KeyInput String
  | SaveKey
  | ForgetKey
  | PickModel String
  | PickSession String
  | NewSessionInput String
  | StartSession
  | QuestionInput String
  | Ask

storageName :: String
storageName = "open-slop-gateway-key"

component :: forall q i o m. MonadAff m => H.Component q i o m
component =
  H.mkComponent
    { initialState: const initial
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handle, initialize = Just Init }
    }

handle :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handle = case _ of
  Init -> do
    stored <- liftEffect (window >>= sessionStorage >>= getItem storageName)
    case stored of
      Just k -> useKey (Key k)
      Nothing -> pure unit
  KeyInput s -> H.modify_ _ { keyInput = s }
  SaveKey -> do
    k <- H.gets (trim <<< _.keyInput)
    unless (k == "") do
      liftEffect (window >>= sessionStorage >>= setItem storageName k)
      useKey (Key k)
  ForgetKey -> do
    liftEffect (window >>= sessionStorage >>= removeItem storageName)
    H.put initial
  PickModel m -> H.modify_ _ { model = m }
  PickSession s -> unless (s == "") (openSession s)
  NewSessionInput s -> H.modify_ _ { newSession = s }
  StartSession -> do
    s <- H.gets (trim <<< _.newSession)
    if s == "" then H.modify_ _ { error = Just "Type a name for the conversation first." }
    else do
      H.modify_ \st -> st
        { sessions = if elem s st.sessions then st.sessions else st.sessions <> [ s ]
        , newSession = ""
        }
      openSession s
  QuestionInput s -> H.modify_ _ { question = s }
  Ask -> do
    st <- H.get
    case st.key of
      Just k | trim st.question /= "", st.session /= "", not (running st.job) -> do
        r <- H.liftAff (Api.submit k { session: st.session, model: st.model, question: trim st.question })
        case r of
          Left e -> H.modify_ _ { error = Just e }
          Right i -> do
            H.modify_ _ { question = "", error = Nothing, job = Just { id: i, seconds: 0.0, phase: Queued 0 } }
            follow k st.session i
      _ -> pure unit

-- | Ask after a job every two seconds until it ends. When it is done, the
-- | conversation is read again, which now holds the answer.
follow :: forall o m. MonadAff m => Key -> String -> Int -> H.HalogenM State Action () o m Unit
follow k s i = do
  H.liftAff (delay (Milliseconds 2000.0))
  r <- H.liftAff (Api.job k i)
  case r of
    Left e -> H.modify_ _ { error = Just e, job = Nothing }
    Right j -> do
      H.modify_ _ { job = Just j }
      case j.phase of
        Done _ -> do
          H.modify_ _ { job = Nothing }
          current <- H.gets _.session
          when (current == s) (openSession s)
        Failed _ -> pure unit
        _ -> follow k s i

useKey :: forall o m. MonadAff m => Key -> H.HalogenM State Action () o m Unit
useKey k = do
  ms <- H.liftAff (Api.models k)
  case ms of
    Left e -> H.modify_ _ { error = Just ("The gateway refused the key or could not be reached: " <> e) }
    Right models -> do
      ss <- H.liftAff (Api.sessions k)
      H.modify_ _
        { key = Just k
        , models = models
        , model = fromMaybe "index" (head models)
        , sessions = either (const []) (map _.name) ss
        , error = either Just (const Nothing) ss
        }

openSession :: forall o m. MonadAff m => String -> H.HalogenM State Action () o m Unit
openSession s =
  H.gets _.key >>= case _ of
    Nothing -> pure unit
    Just k -> do
      r <- H.liftAff (Api.session k s)
      case r of
        Left e -> H.modify_ _ { error = Just e }
        Right turns -> H.modify_ _ { session = s, turns = turns, error = Nothing }

running :: Maybe Job -> Boolean
running = case _ of
  Just { phase: Done _ } -> false
  Just { phase: Failed _ } -> false
  Just _ -> true
  Nothing -> false

render :: forall m. State -> H.ComponentHTML Action () m
render st = HH.main_ $ case st.key of
  Nothing ->
    [ HH.h1_ [ HH.text "open-slop index" ]
    , HH.p_ [ HH.text "The gateway key. It is kept in this tab until the tab closes." ]
    , HH.div [ cls "bar" ]
        [ HH.input [ HP.type_ HP.InputPassword, HP.value st.keyInput, HE.onValueInput KeyInput ]
        , HH.button [ HE.onClick \_ -> SaveKey ] [ HH.text "Use key" ]
        ]
    , errorView st.error
    ]
  Just _ ->
    [ HH.h1_ [ HH.text "open-slop index" ]
    , HH.div [ cls "bar" ]
        [ HH.select [ HE.onValueChange PickModel ]
            (map (\m -> HH.option [ HP.value m, HP.selected (m == st.model) ] [ HH.text m ]) st.models)
        , HH.select [ HE.onValueChange PickSession ]
            ( [ HH.option [ HP.value "", HP.selected (st.session == "") ] [ HH.text "conversation..." ] ]
                <> map (\s -> HH.option [ HP.value s, HP.selected (s == st.session) ] [ HH.text s ]) st.sessions
            )
        , HH.input [ HP.placeholder "new conversation", HP.value st.newSession, HE.onValueInput NewSessionInput ]
        , HH.button [ HE.onClick \_ -> StartSession ] [ HH.text "Start" ]
        , HH.button [ HE.onClick \_ -> ForgetKey ] [ HH.text "Forget key" ]
        ]
    , errorView st.error
    , HH.div_ (map turnView st.turns)
    , maybeView jobView st.job
    , if st.session == "" then HH.p [ cls "ask" ] [ HH.text "Pick or start a conversation to ask a question." ]
      else HH.div_
        [ HH.textarea [ HP.value st.question, HP.placeholder ("Ask " <> st.model), HE.onValueInput QuestionInput ]
        , HH.button [ HP.disabled (running st.job || trim st.question == ""), HE.onClick \_ -> Ask ] [ HH.text "Ask" ]
        ]
    ]

turnView :: forall w i. Turn -> HH.HTML w i
turnView t = HH.div [ cls "turn" ] $ case t.role, t.answer of
  "user", _ -> [ HH.p [ cls "user" ] [ HH.text t.text ] ]
  _, Just a -> [ answerView a ]
  _, Nothing -> [ HH.p_ [ HH.text t.text ] ]

answerView :: forall w i. Answer -> HH.HTML w i
answerView a =
  HH.div_
    [ HH.div_ (Array.concatMap (partView (Array.length a.parts > 1)) a.parts)
    , if null a.sources then HH.text ""
      else HH.ol [ cls "sources" ] (map sourceView a.sources)
    ]

-- | A part's claims, each with its source numbers, then what the sources
-- | do not say. With more than one part, each is headed by what it asks.
partView :: forall w i. Boolean -> Part -> Array (HH.HTML w i)
partView several p =
  (if several then [ HH.p [ cls "ask" ] [ HH.text p.ask ] ] else [])
    <> map claimView p.claims
    <> gapView
  where
  claimView c = HH.p_ [ HH.text c.claim, HH.sup_ [ HH.text (" [" <> joinWith ", " (map show c.sources) <> "]") ] ]
  gapView
    | null p.claims = [ HH.p [ cls "gap" ] [ HH.text ("Not answered from your files: " <> (if p.gap == "" then p.ask else p.gap)) ] ]
    | p.gap /= "" = [ HH.p [ cls "gap" ] [ HH.text ("Not in the sources: " <> p.gap) ] ]
    | otherwise = []

sourceView :: forall w i. Source -> HH.HTML w i
sourceView s =
  HH.li [ cls (if s.cited then "cited" else "uncited") ]
    [ HH.code_ [ HH.text (s.path <> ":" <> show s.lineFrom <> "-" <> show s.lineTo) ]
    , HH.text (if s.heading == "" then "" else "  " <> s.heading)
    ]

jobView :: forall w i. Job -> HH.HTML w i
jobView j = HH.p [ cls "job" ] [ HH.text (describe j.phase <> " (" <> show (floor j.seconds) <> " s)") ]
  where
  describe = case _ of
    Queued 0 -> "Waiting for the index"
    Queued n -> "Waiting behind " <> show n <> " other question" <> (if n == 1 then "" else "s")
    Searching -> "Searching and reranking"
    Answering n -> "Writing the answer: " <> show n <> " characters so far"
    Done _ -> "Done"
    Failed why -> "Failed: " <> why

errorView :: forall w i. Maybe String -> HH.HTML w i
errorView = maybeView \e -> HH.p [ cls "error" ] [ HH.text e ]

maybeView :: forall a w i. (a -> HH.HTML w i) -> Maybe a -> HH.HTML w i
maybeView f = case _ of
  Just x -> f x
  Nothing -> HH.text ""

cls :: forall r i. String -> HP.IProp (class :: String | r) i
cls = HP.class_ <<< H.ClassName