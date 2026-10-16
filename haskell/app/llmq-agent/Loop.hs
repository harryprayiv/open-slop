-- | One run of the agent: ask, act, observe, until it finishes or stops.
--
-- Part of llmq-agent; Main sets up what this module is given.
--
-- ============================================================================
-- ONE STEP
-- ============================================================================
--
--   1. The transcript is fitted to the model's capacity
--      ("OpenSlop.Agent.Transcript") and sent with the schema of the
--      decisions this run offers ("OpenSlop.Agent.Action"). The server
--      samples only JSON of that shape.
--   2. The decision is decoded. A reply that does not decode (cut off, or a
--      server that ignored the schema) becomes the observation, and three
--      in a row end the run.
--   3. The action runs inside the workspace. An edit is written, committed
--      on the run's branch, and followed by the build it triggers, so the
--      model always sees the compiler's answer to its change in the same
--      step.
--   4. The observation is clipped to a third of the prompt, recorded, and
--      the next step begins.
--
-- ============================================================================
-- WHEN IT STOPS
-- ============================================================================
--
--   Finished     the model said Finish, and either it made no edits or the
--                last build is clean with every test suite passing. A
--                Finish that does not meet that is refused with the build
--                report as the observation, and the run goes on.
--   OutOfSteps   the step limit was reached.
--   Stuck        the model repeated one action three times running, or
--                gave three replies in a row that did not decode.
--   ModelFailed  the server failed.
--
-- The step limit is the only bound, and it is a flag. Nothing caps how
-- long a reply, a file or a build report may be beyond what the model's
-- window holds.
module Loop
  ( Agent (..)
  , Ending (..)
  , runAgent
  ) where

import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import OpenSlop.Agent.Action
import OpenSlop.Agent.Oracle (Report, acceptable, renderReport)
import OpenSlop.Agent.Transcript (Step (..), briefAction, messagesFor, observationRoom)
import OpenSlop.Agent.Workspace
import OpenSlop.Capacity (Capacity (..), learn, promptCharsWithin)
import OpenSlop.ChatStream (Ask (..), Chat, Streamed (..), streamChatTo)
import OpenSlop.Http (Client)
import System.IO (hFlush, stderr)

data Agent = Agent
  { client :: Client
  , chat :: Chat
  , capacity :: IORef Capacity
  , maxWait :: Maybe Double
  , workspace :: Workspace
  , kinds :: [Kind]
  , maxSteps :: Int
  , currentBuild :: Maybe (IO (Either Text Report))
  -- ^ the settled state of the latest build
  , buildAfter :: Maybe (Report -> IO (Either Text Report))
  -- ^ the build that follows an edit made after this report
  , lookupSource :: Maybe (Text -> IO Text)
  , searchIndex :: Maybe (Text -> IO Text)
  , commitEdit :: Int -> Text -> IO ()
  -- ^ commit the edit made at this step, with this message
  , logStep :: Value -> IO ()
  -- ^ one step for the run's log
  , note :: Text -> IO ()
  }

data Ending
  = Finished Text
  | OutOfSteps
  | Stuck Text
  | ModelFailed Text
  deriving stock (Show)

data State = State
  { steps :: [Step]
  , lastReport :: Maybe Report
  , edited :: Bool
  , undecodable :: Int
  }

-- | Run the agent on a task, given what to say about the project first.
runAgent :: Agent -> Text -> Text -> Maybe Report -> IO Ending
runAgent a task opening initial = do
  st <- newIORef State {steps = [], lastReport = initial, edited = False, undecodable = 0}
  go st 1
  where
    system = instructions a.kinds
    taskText = "Task:\n" <> task <> "\n\n" <> opening
    go st n
      | n > a.maxSteps = pure OutOfSteps
      | otherwise = do
          s <- readIORef st
          cap <- readIORef a.capacity
          let budget = promptCharsWithin cap 256 a.maxWait
              (msgs, chars) = messagesFor budget system taskText s.steps
              room = observationRoom budget
          a.note ("step " <> tshow n <> ": asking the model (" <> tshow chars <> " characters of prompt)")
          out <- newIORef ("" :: Text)
          thought <- newIORef False
          counted <- newIORef Nothing
          t0 <- getCurrentTime
          r <-
            streamChatTo
              a.client
              a.chat
              cap
              Ask {messages = msgs, schema = Just (decisionSchema a.kinds), outputCap = Nothing, temperature = 0.2}
              Streamed
                { onText = \t -> modifyIORef' out (<> t)
                , onThinking = \t -> do
                    started <- readIORef thought
                    unless started (TIO.hPutStr stderr "  thinking: " >> writeIORef thought True)
                    TIO.hPutStr stderr t >> hFlush stderr
                , onPromptTokens = writeIORef counted . Just
                }
          t1 <- getCurrentTime
          readIORef thought >>= \th -> when th (TIO.hPutStrLn stderr "")
          raw <- readIORef out
          pt <- readIORef counted
          mapM_ (\k -> modifyIORef' a.capacity (\c -> learn c chars k)) pt
          let seconds = realToFrac (diffUTCTime t1 t0) :: Double
          case r of
            Left e -> pure (ModelFailed e)
            Right () -> case decodeDecision raw of
              Left e -> do
                let obs = "Your reply could not be read as a decision (" <> e <> "). Reply with exactly one decision: {\"plan\": ..., \"step\": {\"tag\": ..., \"contents\": {...}}}."
                    bad = s.undecodable + 1
                a.note ("step " <> tshow n <> ": the reply did not decode: " <> e)
                a.logStep (object ["step" .= n, "raw" .= raw, "error" .= e, "promptChars" .= chars, "promptTokens" .= pt, "seconds" .= seconds])
                if bad >= 3
                  then pure (Stuck "three replies in a row did not decode")
                  else do
                    writeIORef st s {steps = s.steps <> [Step n (Left raw) obs], undecodable = bad}
                    go st (n + 1)
              Right d -> do
                a.note ("step " <> tshow n <> ": " <> d.plan)
                a.note ("  " <> briefAction d.step)
                let repeats = length (takeWhile (\p -> fmap (.step) p.decision == Right d.step) (reverse s.steps))
                if repeats >= 2
                  then do
                    a.logStep (object ["step" .= n, "plan" .= d.plan, "action" .= toJSON d.step, "observation" .= ("stopped: a third identical action" :: Text), "promptChars" .= chars, "promptTokens" .= pt, "seconds" .= seconds])
                    pure (Stuck ("the model repeated " <> kindName (kindOf d.step) <> " three times running"))
                  else do
                    (obs0, ending, s') <- act a room s {undecodable = 0} n d
                    let obs = clip room ((if repeats == 1 then "You did exactly this in the last step. " else "") <> obs0)
                    a.logStep
                      ( object
                          [ "step" .= n
                          , "plan" .= d.plan
                          , "action" .= toJSON d.step
                          , "observation" .= obs
                          , "promptChars" .= chars
                          , "promptTokens" .= pt
                          , "seconds" .= seconds
                          ]
                      )
                    writeIORef st s' {steps = s'.steps <> [Step n (Right d) obs]}
                    case ending of
                      Just e -> pure e
                      Nothing -> go st (n + 1)

-- | Carry out one action: its observation, whether the run ends, and the
-- new state.
act :: Agent -> Int -> State -> Int -> Decision -> IO (Text, Maybe Ending, State)
act a room s n d = case d.step of
  BrowseDirectory x -> path x.directory \p -> do
    r <- listDirectory' p
    pure (either id (\es -> if null es then "(empty)" else T.unlines es) r)
  ReadFile x -> path x.path \p ->
    readText p >>= \case
      Left e -> pure ("cannot read " <> x.path <> ": " <> e)
      Right t -> pure (numbered room x.startLine x.stopLine t)
  SearchIndex x -> plain case a.searchIndex of
    Nothing -> pure "there is no index in this run"
    Just f -> f x.query
  LookupSource x -> plain case a.lookupSource of
    Nothing -> pure "there is no source lookup in this run"
    Just f -> f x.query
  ReplaceText x -> edit x.path \p ->
    readText p >>= \case
      Left e -> pure (Left ("cannot read " <> x.path <> ": " <> e))
      Right t -> pure (replaceOnce x.replace x.with t)
  WriteFile x -> edit x.path \_ -> pure (Right x.text)
  Check -> case a.currentBuild of
    Nothing -> pure ("there is no build oracle in this run", Nothing, s)
    Just cur ->
      cur >>= \case
        Left e -> pure ("the build could not be checked: " <> e, Nothing, s)
        Right rep -> pure (renderReport room rep, Nothing, s {lastReport = Just rep})
  Finish x
    | not s.edited -> pure ("finished", Just (Finished x.summary), s)
    | otherwise -> case a.currentBuild of
        Nothing -> pure ("finished", Just (Finished x.summary), s)
        Just cur ->
          cur >>= \case
            Left e -> pure ("Finish refused: the build could not be checked (" <> e <> ")", Nothing, s)
            Right rep
              | acceptable rep -> pure ("finished", Just (Finished x.summary), s {lastReport = Just rep})
              | otherwise ->
                  pure
                    ( "Finish refused: after your edits the build must have no errors and every test suite must pass.\n" <> renderReport room rep
                    , Nothing
                    , s {lastReport = Just rep}
                    )
  where
    plain m = (\o -> (o, Nothing, s)) <$> m
    path given k =
      resolve a.workspace given >>= \case
        Left e -> pure (e, Nothing, s)
        Right p -> (\o -> (o, Nothing, s)) <$> k p
    edit given change =
      resolve a.workspace given >>= \case
        Left e -> pure (e, Nothing, s)
        Right p ->
          change p >>= \case
            Left e -> pure (e, Nothing, s)
            Right new ->
              writeText p new >>= \case
                Left e -> pure ("cannot write " <> given <> ": " <> e, Nothing, s)
                Right () -> do
                  a.commitEdit n (firstLine d.plan)
                  let done = "Wrote " <> relativeTo a.workspace p <> "."
                  case (a.buildAfter, s.lastReport, a.currentBuild) of
                    (Just after, Just before, _) -> report done (after before)
                    (_, _, Just cur) -> report done cur
                    _ -> pure (done <> " There is no build oracle in this run.", Nothing, s {edited = True})
    report done check = do
      a.note "  waiting for the build"
      check >>= \case
        Left e -> pure (done <> " The build could not be checked: " <> e, Nothing, s {edited = True})
        Right rep -> do
          when (acceptable rep) (a.note "  the build is clean and the tests pass")
          pure (done <> "\n" <> renderReport (room - T.length done - 1) rep, Nothing, s {edited = True, lastReport = Just rep})
    firstLine t = T.take 120 (T.takeWhile (/= '\n') t)

clip :: Int -> Text -> Text
clip n t
  | T.length t <= n = t
  | otherwise = T.take (max 0 (n - 60)) t <> "\n[cut to fit the model's window]"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
