-- | Questions to the index as jobs, for the web page.
--
-- An answer from the index takes three to five minutes on oracle: the
-- reranker reads thirty chunks in about a minute, and the chat model
-- writes about 200 tokens at 1.75 a second (measured 2026-10-21). A
-- browser request held open that long is lost with the tab, a suspended
-- laptop or a dropped connection, and the answer with it. So the page does
-- not ask through /v1/chat/completions. It submits a job, which returns at
-- once with an id, and asks after the job every few seconds; the job runs
-- here whether or not anything is asking after it, and its answer is
-- stored in the conversation when it is done.
--
-- ============================================================================
-- ONE AT A TIME
-- ============================================================================
--
-- Jobs run one after another on a single thread, in the order they were
-- submitted. The servers behind the index serve one request at a time, and
-- llama-server keeps one prompt cache: two questions interleaved on it
-- throw out each other's cache, and on 2026-10-21 that turned a 75-second
-- call into a 2,000-second one. A queued job reports its position, so the
-- page can say how many are ahead of it.
--
-- ============================================================================
-- CONVERSATIONS
-- ============================================================================
--
-- A job names a session. The session is llmq-index's: the same tables
-- `llmq-index chat --session NAME` reads and writes, so a conversation
-- started on the page can be continued at the terminal and the other way
-- round. The question is rewritten against the session's earlier turns
-- before searching, as in llmq-index chat. When the answer is done both
-- turns are stored, the assistant turn with the whole cited answer beside
-- it, which is what the page shows when the conversation is opened again.
--
-- A finished job is kept for an hour after it ends, for a page that asks
-- after it late, and then forgotten; its answer is in the session.
module OpenSlop.Gateway.Asks
  ( Asks
  , newAsks
  , submit
  , jobStatus
  , indexModels
  , scopeOf
  , answerValue
  , unanswered
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forever, void)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import OpenSlop.Rag.Ask (Asking (..), Selection (..), answerWith, select)
import OpenSlop.Rag.Retrieve (Answer (..), Claim (..), Part (..), Chat (..))
import OpenSlop.Rag.Store (Hit (..), Stats (..), addTurn, openSession, sessionTurns, stats)
import System.FilePath (takeFileName)

-- | Where a job is. Searching covers rewriting the question against the
-- conversation, embedding it, the hybrid search and the reranker, which
-- "OpenSlop.Rag.Ask".select does as one step. Answering counts the
-- characters of the answer's JSON received so far.
data Phase
  = Queued
  | Searching
  | Answering Int
  | Done Value
  | Failed Text

data Job = Job
  { session :: Text
  , model :: Text
  , question :: Text
  , submitted :: POSIXTime
  , started :: Maybe POSIXTime
  , ended :: Maybe POSIXTime
  , phase :: Phase
  }

data Asks = Asks
  { asking :: Asking
  , jobs :: IORef (Map Int Job)
  , queue :: Chan Int
  , counter :: IORef Int
  , logLine :: Text -> IO ()
  }

-- | The job store and the thread that runs the jobs.
newAsks :: Asking -> (Text -> IO ()) -> IO Asks
newAsks asking logLine = do
  jobs <- newIORef Map.empty
  queue <- newChan
  counter <- newIORef 0
  let a = Asks {asking, jobs, queue, counter, logLine}
  void (forkIO (forever (readChan queue >>= runJob a)))
  pure a

-- | Queue a question. Refused when the model is not one of the index's or
-- the question or the session name is empty.
submit :: Asks -> Text -> Text -> Text -> IO (Either Text Int)
submit a sessionName m q
  | T.null (T.strip q) = pure (Left "the question is empty")
  | T.null (T.strip sessionName) = pure (Left "the session name is empty")
  | otherwise =
      scopeOf a.asking m >>= \case
        Left why -> pure (Left why)
        Right _ -> do
          t <- getPOSIXTime
          i <- atomicModifyIORef' a.counter (\n -> (n + 1, n + 1))
          atomicModifyIORef' a.jobs \js ->
            ( Map.insert i (Job {session = T.strip sessionName, model = m, question = T.strip q, submitted = t, started = Nothing, ended = Nothing, phase = Queued}) (forgetOld t js)
            , ()
            )
          writeChan a.queue i
          a.logLine ("index job " <> tshow i <> " queued for " <> m <> " in session " <> sessionName)
          pure (Right i)
  where
    forgetOld t = Map.filter \j -> maybe True (\e -> t - e < 3600) j.ended

-- | A job as JSON, or Nothing when there is no such job (never submitted,
-- or finished more than an hour ago).
jobStatus :: Asks -> Int -> IO (Maybe Value)
jobStatus a i = do
  js <- readIORef a.jobs
  t <- getPOSIXTime
  pure $ flip fmap (Map.lookup i js) \j ->
    let ahead = Map.size (Map.filter (\k -> isQueued k.phase || isRunning k.phase) (fst (Map.split i js)))
     in object
          [ "id" .= i
          , "session" .= j.session
          , "model" .= j.model
          , "question" .= j.question
          , "seconds" .= (realToFrac (maybe t id j.ended - maybe j.submitted id j.started) :: Double)
          , "phase" .= case j.phase of
              Queued -> object ["tag" .= ("queued" :: Text), "ahead" .= ahead]
              Searching -> object ["tag" .= ("searching" :: Text)]
              Answering n -> object ["tag" .= ("answering" :: Text), "characters" .= n]
              Done v -> object ["tag" .= ("done" :: Text), "answer" .= v]
              Failed why -> object ["tag" .= ("failed" :: Text), "reason" .= why]
          ]
  where
    isQueued = \case
      Queued -> True
      _ -> False
    isRunning = \case
      Searching -> True
      Answering _ -> True
      _ -> False

runJob :: Asks -> Int -> IO ()
runJob a i =
  readIORef a.jobs >>= \js -> case Map.lookup i js of
    Nothing -> pure ()
    Just j -> do
      t0 <- getPOSIXTime
      set (\x -> x {started = Just t0, phase = Searching})
      r <- try @SomeException (answer j)
      t1 <- getPOSIXTime
      case r of
        Left e -> finish t1 (Failed (T.pack (takeWhile (/= '\n') (displayException e))))
        Right (Left why) -> finish t1 (Failed why)
        Right (Right v) -> finish t1 (Done v)
      a.logLine ("index job " <> tshow i <> " ended after " <> tshow (floor (t1 - t0) :: Int) <> "s")
  where
    set f = atomicModifyIORef' a.jobs \js -> (Map.adjust f i js, ())
    finish t p = set (\x -> x {ended = Just t, phase = p})
    answer j =
      scopeOf a.asking j.model >>= \case
        Left why -> pure (Left why)
        Right sc -> do
          scopeRef <- newIORef sc
          let one = a.asking {scope = scopeRef, note = \t -> a.logLine ("index job " <> tshow i <> ": " <> t)}
          sid <- openSession one.conn j.session
          history <- sessionTurns one.conn sid
          select one history j.question >>= \case
            -- Nothing in scope matches: an answer with one unanswered
            -- part, as the gateway's index model gives. Every other
            -- failure (a server down) stays a failure, so an outage is
            -- never shown as an answer that the sources are silent.
            Left why
              | "nothing " `T.isPrefixOf` why -> do
                  let v = unanswered j.question why
                  store one sid j ("Not in the sources: " <> why) v
                  pure (Right v)
              | otherwise -> pure (Left why)
            Right sel -> do
              received <- newIORef (0 :: Int)
              let onText t = do
                    n <- atomicModifyIORef' received (\c -> let c' = c + T.length t in (c', c'))
                    set (\x -> x {phase = Answering n})
              set (\x -> x {phase = Answering 0})
              answerWith one history j.question sel.packed onText >>= \case
                Left e -> pure (Left e)
                Right ans -> do
                  let v = answerValue ans
                  store one sid j ans.text v
                  pure (Right v)
    store one sid j text v = do
      addTurn one.conn sid "user" j.question Nothing Nothing
      addTurn one.conn sid "assistant" text (Just v) (Just one.chatTo.model)

-- | The index's model ids: index, then index/NAME for each indexed root,
-- NAME being the root's last path component.
indexModels :: Asking -> IO [Text]
indexModels a = do
  rs <- indexRoots a
  pure ("index" : ["index/" <> n | (n, _) <- rs])

-- | What a model id searches: everything for index, the root's path for
-- index/NAME, or why the name is not one of the index's.
scopeOf :: Asking -> Text -> IO (Either Text [Text])
scopeOf a m
  | m == "index" = pure (Right [])
  | Just wanted <- T.stripPrefix "index/" m = do
      rs <- indexRoots a
      pure case [p | (n, p) <- rs, n == wanted] of
        [] -> Left ("no indexed root is called " <> wanted <> "; the index's models are " <> T.intercalate ", " ("index" : ["index/" <> n | (n, _) <- rs]))
        ps -> Right [T.dropWhileEnd (== '/') p <> "/" | p <- ps]
  | otherwise = pure (Left (m <> " is not one of the index's models"))

indexRoots :: Asking -> IO [(Text, Text)]
indexRoots a = do
  st <- stats a.conn
  pure [(T.pack (takeFileName (T.unpack (T.dropWhileEnd (== '/') r))), r) | (r, _) <- st.roots]

-- | The cited answer as JSON: each part with what it asks, its claims and
-- the numbers of the sources each rests on, and its gap; each source with
-- its number, path, lines, heading and whether a claim cited it.
answerValue :: Answer -> Value
answerValue ans =
  object
    [ "parts"
        .= [ object
               [ "ask" .= p.ask
               , "claims" .= [object ["claim" .= c.claim, "sources" .= c.sources] | c <- p.claims]
               , "gap" .= p.gap
               ]
           | p <- ans.parts
           ]
    , "sources"
        .= [ object
               [ "number" .= k
               , "path" .= h.path
               , "lineFrom" .= h.lineFrom
               , "lineTo" .= h.lineTo
               , "heading" .= h.heading
               , "cited" .= (k `elem` ans.cited)
               ]
           | (k, h) <- zip [1 :: Int ..] ans.sources
           ]
    ]

-- | The same shape when nothing in scope matched the question.
unanswered :: Text -> Text -> Value
unanswered q why =
  object
    [ "parts" .= [object ["ask" .= q, "claims" .= ([] :: [Value]), "gap" .= why]]
    , "sources" .= ([] :: [Value])
    ]

tshow :: (Show a) => a -> Text
tshow = T.pack . show
