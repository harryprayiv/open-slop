-- | The chat's screen: the same title and status bars as the model table at
-- the top, a key bar at the bottom, an input line above it, and the
-- conversation scrolling in between.
--
-- Part of llmq-models; Main describes the program.
--
-- ============================================================================
-- HOW THE SCREEN IS KEPT IN ONE PIECE
-- ============================================================================
--
-- The conversation area is a terminal scroll region (DECSTBM): rows 3 to
-- height-2 scroll as text arrives, and the bars above and below stay where
-- they are without being redrawn line by line. The conversation's write
-- position is kept in the terminal's one saved-cursor slot (ESC 7 / ESC 8),
-- which nothing else uses; every other write goes to an absolute row.
--
-- Three threads write to the terminal: the conversation, the thinking
-- indicator on the input line, and the status bar's once-a-second refresh.
-- Every write takes one lock, so no escape sequence is ever split by
-- another thread's output.
--
-- Answers are word-wrapped here rather than by the terminal, so every
-- wrapped line keeps the coloured bar that says whose answer it is.
--
-- ============================================================================
-- KEYS AT THE INPUT LINE
-- ============================================================================
--
-- Input is read a key at a time, so Esc can leave, which a line read by the
-- terminal cannot do.
--
--   enter         send               esc, ctrl-d   back to the models
--   backspace     delete a character ctrl-u        clear the line
--   ctrl-c        at the input line, back to the models; while a model is
--                 answering, stops that answer (handled in Chat)
module ChatScreen
  ( Screen (..)
  , openScreen
  , closeScreen
  , drawTop
  , setBottom
  , block
  , stream
  , endBlock
  , note
  , readInput
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (AsyncException (..), try)
import Data.Char (isControl)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Style
import System.IO

data Screen = Screen
  { lock :: MVar ()
  , height :: Int
  , width :: Int
  , column :: IORef Int
  -- ^ visible column of the conversation's write position
  , word :: IORef Text
  -- ^ the word being streamed, held until a space shows where it ends
  , barColour :: IORef Int
  , wordColour :: IORef Int
  -- ^ the colour of the word being held, so it is written in the colour of
  -- the text it came from however the block ends
  , fresh :: IORef Bool
  -- ^ nothing written yet, so the first block needs no blank line above it
  , inputLine :: IORef Text
  -- ^ what the input row shows: the prompt and typing, or the indicator
  , keyLine :: IORef Text
  }

openScreen :: Int -> Int -> IO Screen
openScreen h w = do
  s <-
    Screen
      <$> newMVar ()
      <*> pure h
      <*> pure w
      <*> newIORef 0
      <*> newIORef ""
      <*> newIORef cMuted
      <*> newIORef cText
      <*> newIORef True
      <*> newIORef ""
      <*> newIORef ""
  hSetEncoding stdin utf8
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  withMVar s.lock \_ -> do
    TIO.putStr ("\ESC[2J\ESC[3;" <> T.pack (show (h - 2)) <> "r\ESC[3;1H\ESC7\ESC[?25h")
    hFlush stdout
  pure s

-- | Release the scroll region and clear, leaving the terminal as the model
-- table expects it.
closeScreen :: Screen -> IO ()
closeScreen s = withMVar s.lock \_ -> do
  TIO.putStr "\ESC[r\ESC[2J\ESC[H\ESC[?25l"
  hFlush stdout

-- | The bars above the conversation, one per row from the top.
drawTop :: Screen -> [Text] -> IO ()
drawTop s ls = withMVar s.lock \_ -> do
  mapM_ (\(i, l) -> TIO.putStr (at i <> clip s.width l <> "\ESC[K")) (zip [1 :: Int ..] ls)
  cursorToInput s
  hFlush stdout

-- | Replace the input row and the key bar.
setBottom :: Screen -> Text -> Text -> IO ()
setBottom s input keys = do
  writeIORef s.inputLine input
  writeIORef s.keyLine keys
  withMVar s.lock \_ -> drawBottom s >> hFlush stdout

drawBottom :: Screen -> IO ()
drawBottom s = do
  i <- readIORef s.inputLine
  k <- readIORef s.keyLine
  TIO.putStr (at s.height <> clip s.width (bg cPanel (padTo s.width k)) <> "\ESC[K")
  TIO.putStr (at (s.height - 1) <> clip s.width i <> "\ESC[K")

cursorToInput :: Screen -> IO ()
cursorToInput s = do
  i <- readIORef s.inputLine
  TIO.putStr ("\ESC[" <> T.pack (show (s.height - 1)) <> ";" <> T.pack (show (min s.width (visibleLength i + 1))) <> "H")

at :: Int -> Text
at row = "\ESC[" <> T.pack (show row) <> ";1H"

-- | Write into the conversation at its saved position, then put the cursor
-- back on the input line.
conversation :: Screen -> Text -> IO ()
conversation s t = withMVar s.lock \_ -> do
  TIO.putStr ("\ESC8" <> t <> "\ESC7")
  drawBottom s
  cursorToInput s
  hFlush stdout

-- | Start a new block: a blank line, then a heading line, then the body
-- continues on the next line behind a bar in the given colour.
block :: Screen -> Int -> Text -> IO ()
block s colour heading = do
  first <- readIORef s.fresh
  writeIORef s.fresh False
  writeIORef s.barColour colour
  writeIORef s.word ""
  writeIORef s.column 2
  conversation s ((if first then "" else "\n\n") <> heading <> "\n" <> fg colour "▌ ")

-- | Stream plain text into the current block in the given colour, wrapping
-- at word boundaries so every line starts with the block's bar.
--
-- The text must be plain. Colour is applied here, a word at a time, because
-- wrapping counts characters: an escape sequence inside the text would be
-- counted as width and split across lines.
stream :: Screen -> Int -> Text -> IO ()
stream s colour t = writeIORef s.wordColour colour >> mapM_ step (T.unpack t)
  where
    step c
      | c == '\n' = flushWord >> newLine
      | c == ' ' = flushWord >> space
      | isControl c = pure ()
      | otherwise = modifyIORef' s.word (`T.snoc` c)
    maxCol = s.width - 2
    flushWord = do
      w <- readIORef s.word
      if T.null w
        then pure ()
        else do
          writeIORef s.word ""
          col <- readIORef s.column
          if col + T.length w > maxCol && col > 2
            then newLine >> emit w
            else emit w
    emit w = do
      modifyIORef' s.column (+ T.length w)
      conversation s (fg colour w)
    -- flushWord writes in `colour`, which stream has just stored as the
    -- held word's colour, so a word never changes colour at a block's end.
    space = do
      col <- readIORef s.column
      if col + 1 > maxCol then newLine else modifyIORef' s.column (+ 1) >> conversation s " "
    newLine = do
      bar <- readIORef s.barColour
      writeIORef s.column 2
      conversation s ("\n" <> fg bar "▌ ")

-- | Finish the current block: whatever word is still held is written, in
-- the colour of the text it came from.
endBlock :: Screen -> IO ()
endBlock s = do
  colour <- readIORef s.wordColour
  stream s colour " "

-- | A dim line under the current block, such as an answer's timing.
note :: Screen -> Text -> IO ()
note s t = do
  colour <- readIORef s.barColour
  writeIORef s.column 2
  conversation s ("\n" <> fg colour "▌ " <> t)

-- | Read one line at the input row. Nothing means leave the chat: Esc,
-- Ctrl-D on an empty line, or Ctrl-C.
readInput :: Screen -> Text -> Text -> IO (Maybe Text)
readInput s prompt keys = go ""
  where
    render buf =
      let room = s.width - visibleLength prompt - 2
          shown = if T.length buf > room then "…" <> T.takeEnd (room - 1) buf else buf
       in setBottom s (prompt <> fg cText shown) keys
    go buf = do
      render buf
      r <- try getChar :: IO (Either AsyncException Char)
      case r of
        Left UserInterrupt -> pure Nothing
        Left e -> ioError (userError (show e))
        Right c -> case c of
          '\n' -> pure (Just buf)
          '\r' -> pure (Just buf)
          '\ESC' -> do
            more <- hWaitForInput stdin 30
            if more
              then drain >> go buf
              else pure Nothing
          '\EOT' | T.null buf -> pure Nothing
          '\NAK' -> go ""
          '\DEL' -> go (T.dropEnd 1 buf)
          '\b' -> go (T.dropEnd 1 buf)
          _ | isControl c -> go buf
          _ -> go (T.snoc buf c)
    -- The rest of an escape sequence (an arrow key, say), which the input
    -- line does not use.
    drain = do
      more <- hWaitForInput stdin 10
      if more then getChar >> drain else pure ()
