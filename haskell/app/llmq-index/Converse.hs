-- | Asking the index: one question, or a conversation kept in the database.
--
-- Part of llmq-index; Main describes the program, "OpenSlop.Rag.Retrieve"
-- describes one turn, and "OpenSlop.Rag.Ask" chooses the sources and asks
-- the model. This module adds the terminal around it: the raw JSON
-- of the answer streams to stderr as progress, the answer is then printed
-- claim by claim with its sources, the sources follow with the cited ones
-- marked, and in a conversation every turn is stored under the session's
-- name, so
-- `llmq-index chat --session NAME` continues where it stopped, on any
-- machine that reaches the database.
--
-- The model's capacity is worked out once per session from its server, the
-- benchmark and the catalogue, and refined from the prompt token counts the
-- server reports, so how many sources fit grows with the model and the
-- hardware. The current figures are printed at the start.
module Converse
  ( askOnce
  , converse
  ) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (object, toJSON, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import OpenSlop.Capacity (describeCapacity)
import OpenSlop.Rag.Ask (Asking (..), Selection (..), answerWith, select)
import OpenSlop.Rag.Retrieve
import OpenSlop.Rag.Store (Hit (..), addTurn, openSession, sessionTurns)
import System.Directory (makeAbsolute)
import System.IO (hFlush, hIsEOF, stderr, stdin, stdout)

say :: Text -> IO ()
say = TIO.hPutStrLn stderr . ("llmq-index: " <>)

-- | One turn on the terminal: select, then answer with the raw JSON
-- streaming to stderr, then the rendered answer and its sources.
turn :: Asking -> [(Text, Text)] -> Text -> IO (Either Text Answer)
turn a history question =
  select a history question >>= \case
    Left e -> pure (Left e)
    Right sel -> do
      r <- answerWith a history question sel.packed (\t -> TIO.hPutStr stderr t >> hFlush stderr)
      TIO.hPutStrLn stderr ""
      forM_ r \ans -> TIO.putStrLn ans.text >> showSources ans
      pure r

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
  when (null ans.claims) (say "the answer makes no claim from your files")
  let open = [p.ask | p <- ans.parts, null p.claims]
  unless (null ans.claims || null open) (say ("not answered from your files: " <> T.intercalate "; " open))
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