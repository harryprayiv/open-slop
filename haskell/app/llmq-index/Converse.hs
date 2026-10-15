-- | Asking the index: one question, or a conversation kept in the database.
--
-- Part of llmq-index; Main describes the program, and "OpenSlop.Rag.Retrieve"
-- describes one turn. This module adds the terminal around it: the answer is
-- printed as it streams, the sources follow with the cited ones marked, and
-- in a conversation every turn is stored under the session's name, so
-- `llmq-index chat --session NAME` continues where it stopped, on any
-- machine that reaches the database.
--
-- The model's capacity is worked out once per session from its server, the
-- benchmark and the catalogue, and refined from the prompt token counts the
-- server reports, so how many sources fit grows with the model and the
-- hardware. The current figures are printed at the start.
module Converse
  ( Asking (..)
  , askOnce
  , converse
  ) where

import Control.Exception (AsyncException (..), throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (object, toJSON, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import OpenSlop.Capacity (Capacity (..), describeCapacity, learn)
import OpenSlop.Http (Client)
import OpenSlop.Rag.Embed (Embedder)
import OpenSlop.Rag.Retrieve
import OpenSlop.Rag.Store (Connection, Hit (..), addTurn, openSession, sessionTurns)
import System.Directory (makeAbsolute)
import System.IO (hFlush, hIsEOF, stderr, stdin, stdout)

data Asking = Asking
  { client :: Client
  , conn :: Connection
  , embedWith :: Embedder
  , chatTo :: Chat
  , capacity :: IORef Capacity
  , depth :: Int
  , maxWait :: Maybe Double
  , scope :: IORef [Text]
  }

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

-- | One turn: rewrite against the history, retrieve, pack, stream, judge.
-- Returns the answer, or why there is none.
turn :: Asking -> [(Text, Text)] -> Text -> IO (Either Text Answer)
turn a history question = do
  cap <- readIORef a.capacity
  standalone <- condense a.client a.chatTo cap history question
  case standalone of
    Left e -> pure (Left e)
    Right q -> do
      when (q /= question) (say ("searching for: " <> q))
      sc <- readIORef a.scope
      found <- retrieve a.client a.conn a.embedWith Retrieval {depth = a.depth, limit = 2 * a.depth, scope = sc} q
      case found of
        Left e -> pure (Left e)
        Right [] -> pure (Left (if null sc then "nothing in the index matches that question" else "nothing under " <> T.intercalate ", " sc <> " matches that question"))
        Right hits -> do
          let good = relevant hits
              packed = packSources cap a.maxWait (historyChars cap a.maxWait history question) good
          say (T.pack (show (length good)) <> " relevant of " <> T.pack (show (length hits)) <> " found, " <> T.pack (show (length packed)) <> " fit; answering")
          r <- try (answerStream a.client a.chatTo cap a.maxWait history question packed (\t -> TIO.putStr t >> hFlush stdout))
          TIO.putStrLn ""
          case r of
            Left UserInterrupt -> pure (Left "stopped")
            Left e -> throwIO e
            Right (Left e) -> pure (Left e)
            Right (Right ans) -> do
              forM_ ans.promptTokens \n -> modifyIORef' a.capacity (\c -> learn c ans.promptChars n)
              showSources ans
              pure (Right ans)

showSources :: Answer -> IO ()
showSources ans = do
  TIO.putStrLn ""
  forM_ (zip [1 :: Int ..] ans.sources) \(n, h) ->
    TIO.putStrLn
      ( (if n `elem` ans.cited then "* [" else "  [")
          <> T.pack (show n)
          <> "] "
          <> h.path
          <> ":"
          <> T.pack (show h.lineFrom)
          <> "-"
          <> T.pack (show h.lineTo)
          <> (if T.null h.heading then "" else "  " <> h.heading)
      )
  when (null ans.cited) (say "the answer cites no source; treat it as unsupported by your files")
  unless (null ans.invented) (say ("the answer cites sources it was not given: " <> T.pack (show ans.invented)))

askOnce :: Asking -> Text -> IO Bool
askOnce a q = do
  readIORef a.capacity >>= say . describeCapacity
  turn a [] q >>= \case
    Left e -> say e >> pure False
    Right _ -> pure True

-- | A conversation on the terminal, stored under the session's name.
converse :: Asking -> Maybe Text -> IO ()
converse a named = do
  name <- maybe (T.pack . formatTime defaultTimeLocale "%Y-%m-%d-%H%M%S" <$> getZonedTime) pure named
  sid <- openSession a.conn name
  earlier <- sessionTurns a.conn sid
  cap <- readIORef a.capacity
  say ("session " <> name <> (if null earlier then ", new" else ", " <> T.pack (show (length earlier)) <> " earlier turns"))
  say (describeCapacity cap)
  say "/sources shows the last answer's sources in full, /under PATH limits the search, /under alone clears it, /scope shows it, /new starts another session, /quit leaves; ctrl-c stops an answer"
  lastAnswer <- newIORef Nothing
  loop sid name lastAnswer
  where
    loop sid name lastAnswer = do
      TIO.putStr "you> " >> hFlush stdout
      eof <- hIsEOF stdin
      if eof
        then pure ()
        else do
          line <- T.strip <$> TIO.getLine
          case T.words line of
            [] -> loop sid name lastAnswer
            ["/quit"] -> pure ()
            ["/exit"] -> pure ()
            ["/new"] -> converse a Nothing
            ["/scope"] -> do
              sc <- readIORef a.scope
              say (if null sc then "searching everything" else "searching under " <> T.intercalate ", " sc)
              loop sid name lastAnswer
            ["/under"] -> writeIORef a.scope [] >> say "searching everything" >> loop sid name lastAnswer
            ("/under" : ps) -> do
              absolute <- traverse (fmap T.pack . makeAbsolute . T.unpack) ps
              writeIORef a.scope absolute
              say ("searching under " <> T.intercalate ", " absolute)
              loop sid name lastAnswer
            ["/sources"] -> do
              readIORef lastAnswer >>= \case
                Nothing -> say "no answer yet"
                Just ans -> forM_ (zip [1 :: Int ..] ans.sources) \(n, h) -> do
                  TIO.putStrLn ("[" <> T.pack (show n) <> "] " <> h.path <> ":" <> T.pack (show h.lineFrom) <> "-" <> T.pack (show h.lineTo))
                  TIO.putStrLn h.body
                  TIO.putStrLn ""
              loop sid name lastAnswer
            (cmd : _) | "/" `T.isPrefixOf` cmd -> say ("unknown command " <> cmd) >> loop sid name lastAnswer
            _ -> do
              history <- sessionTurns a.conn sid
              turn a history line >>= \case
                Left e -> say e
                Right ans -> do
                  addTurn a.conn sid "user" line Nothing Nothing
                  addTurn
                    a.conn
                    sid
                    "assistant"
                    ans.text
                    (Just (toJSON [object ["path" .= h.path, "lineFrom" .= h.lineFrom, "lineTo" .= h.lineTo, "heading" .= h.heading] | h <- ans.sources]))
                    (Just a.chatTo.model)
                  writeIORef lastAnswer (Just ans)
              loop sid name lastAnswer
