-- | The chat's screen: the same title and status bars as the model table at
-- the top, a key bar at the bottom, an input line above it, and the
-- conversation in between, which can be scrolled back at any time.
--
-- Part of llmq-models; Main describes the program.
--
-- ============================================================================
-- THE CONVERSATION IS KEPT HERE, NOT IN THE TERMINAL
-- ============================================================================
--
-- Every line of the conversation is kept in memory, already wrapped and
-- coloured, and the screen shows whichever part of it the view is on. An
-- earlier version wrote the conversation into a terminal scroll region
-- instead, which kept the bars in place but lost every line that scrolled
-- off the top of the region, so the start of a long answer was gone.
--
-- The view follows the newest line until it is scrolled. Scrolled back, it
-- stays on the same lines while answers keep arriving below, and the bottom
-- row of the conversation says how many lines are below. Scrolling works
-- while a model is answering as well as at the input line.
--
-- Drawing is proportionate to what changed: a word added to the line being
-- written redraws that one row, and only a new line, a new block or a
-- scroll redraws the whole conversation area.
--
-- ============================================================================
-- KEYS
-- ============================================================================
--
-- A thread reads every key for as long as the chat is open. Scrolling keys
-- act at once, even while a model is answering; everything else is queued
-- for the input line.
--
--   pgup pgdn     a page back or forward   up down     a line
--   home          the start                end         the newest line, and
--                                                      follow again
--   mouse wheel   three lines. Turning on the wheel means the terminal
--                 passes mouse clicks to the program, so selecting text
--                 with the mouse needs shift held while dragging.
--   enter         send                     esc, ctrl-d back to the models
--   backspace     delete a character       ctrl-u      clear the line
--   ctrl-c        at the input line, back to the models; while a model is
--                 answering, stops that answer (handled in Chat)
--
-- ============================================================================
-- ONE WRITER AT A TIME
-- ============================================================================
--
-- Four threads draw: the conversation, the thinking indicator on the input
-- line, the status bar's once-a-second refresh, and the key reader when it
-- scrolls. Every draw takes one lock, so no escape sequence is ever split
-- by another thread's output.
module ChatScreen
  ( Screen
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

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (AsyncException (..), IOException, try)
import Data.Char (isControl, isDigit)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Style
import System.IO

-- | What the key reader hands to the input line.
data Key = KChar Char | KEnter | KEsc | KBack | KClear | KEof

data Screen = Screen
  { lock :: MVar ()
  , height :: Int
  , width :: Int
  , lines' :: IORef (Seq Text)
  -- ^ finished lines, coloured, oldest first
  , current :: IORef Text
  -- ^ the line being written, coloured
  , column :: IORef Int
  -- ^ visible width of the line being written
  , word :: IORef Text
  -- ^ the word being streamed, held until a space shows where it ends
  , barColour :: IORef Int
  , wordColour :: IORef Int
  -- ^ the colour of the word being held, so it is written in the colour of
  -- the text it came from however the block ends
  , fresh :: IORef Bool
  -- ^ nothing written yet, so the first block needs no blank line above it
  , offset :: IORef Int
  -- ^ lines scrolled back from the newest; 0 means follow new lines
  , inputLine :: IORef Text
  , keyLine :: IORef Text
  , keys :: Chan Key
  , reader :: IORef (Maybe ThreadId)
  }

-- | The conversation area: rows 3 to height-2.
regionTop, regionHeight :: Screen -> Int
regionTop _ = 3
regionHeight s = max 1 (s.height - 4)

openScreen :: Int -> Int -> IO Screen
openScreen h w = do
  s <-
    Screen
      <$> newMVar ()
      <*> pure h
      <*> pure w
      <*> newIORef Seq.empty
      <*> newIORef ""
      <*> newIORef 0
      <*> newIORef ""
      <*> newIORef cMuted
      <*> newIORef cText
      <*> newIORef True
      <*> newIORef 0
      <*> newIORef ""
      <*> newIORef ""
      <*> newChan
      <*> newIORef Nothing
  hSetEncoding stdin utf8
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  withMVar s.lock \_ -> do
    -- Clear, show the cursor, and turn on wheel reporting in SGR form.
    TIO.putStr "\ESC[2J\ESC[?25h\ESC[?1000h\ESC[?1006h"
    hFlush stdout
  t <- forkIO (readKeys s)
  writeIORef s.reader (Just t)
  pure s

-- | Stop the key reader, turn mouse reporting off and clear, leaving the
-- terminal as the model table expects it.
closeScreen :: Screen -> IO ()
closeScreen s = do
  readIORef s.reader >>= mapM_ killThread
  withMVar s.lock \_ -> do
    TIO.putStr "\ESC[?1000l\ESC[?1006l\ESC[2J\ESC[H\ESC[?25l"
    hFlush stdout

-- | The bars above the conversation, one per row from the top.
drawTop :: Screen -> [Text] -> IO ()
drawTop s ls = withMVar s.lock \_ -> do
  mapM_ (\(i, l) -> TIO.putStr (at i <> clip s.width l <> "\ESC[K")) (zip [1 :: Int ..] ls)
  cursorToInput s
  hFlush stdout

-- | Replace the input row and the key bar.
setBottom :: Screen -> Text -> Text -> IO ()
setBottom s input k = do
  writeIORef s.inputLine input
  writeIORef s.keyLine k
  withMVar s.lock \_ -> drawBottom s >> cursorToInput s >> hFlush stdout

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

-- ===========================================================================
-- Drawing the conversation from the kept lines
-- ===========================================================================

-- | All lines, the one being written last, and the index of the first line
-- the view shows. The offset is clamped here so a scroll past either end
-- simply stops.
view :: Screen -> IO (Seq Text, Int, Int)
view s = do
  done <- readIORef s.lines'
  cur <- readIORef s.current
  off0 <- readIORef s.offset
  let everything = done |> cur
      total = Seq.length everything
      maxOff = max 0 (total - regionHeight s)
      off = max 0 (min maxOff off0)
  writeIORef s.offset off
  pure (everything, max 0 (total - regionHeight s - off), off)

-- | Redraw the whole conversation area. Called with the lock held.
drawRegion :: Screen -> IO ()
drawRegion s = do
  (everything, start, off) <- view s
  let shown = toList (Seq.take (regionHeight s) (Seq.drop start everything))
      rows = shown <> replicate (regionHeight s - length shown) ""
      below = Seq.length everything - start - length shown
  mapM_
    (\(i, l) -> TIO.putStr (at (regionTop s + i) <> clip s.width l <> "\ESC[K"))
    (zip [0 ..] rows)
  if off > 0
    then
      TIO.putStr
        ( at (regionTop s + regionHeight s - 1)
            <> clip s.width (bg cSel (padTo s.width (fg cYellow ("  ▼ " <> T.pack (show below) <> " more lines below") <> fg cGrey "   end or pgdn to catch up")))
            <> "\ESC[K"
        )
    else pure ()
  drawBottom s
  cursorToInput s
  hFlush stdout

-- | Redraw only the row of the line being written, when the view is
-- following it. Called with the lock held.
drawCurrent :: Screen -> IO ()
drawCurrent s = do
  (everything, start, off) <- view s
  if off > 0
    then pure ()
    else do
      cur <- readIORef s.current
      let row = regionTop s + (Seq.length everything - 1 - start)
      TIO.putStr (at row <> clip s.width cur <> "\ESC[K")
      cursorToInput s
      hFlush stdout

-- | Append to the line being written.
append :: Screen -> Text -> Int -> IO ()
append s t w = withMVar s.lock \_ -> do
  modifyIORef' s.current (<> t)
  modifyIORef' s.column (+ w)
  drawCurrent s

-- | Finish the line being written and start a new one with the given text.
-- A view scrolled back keeps showing the same lines, so its offset grows by
-- the line that arrived below it.
newLineWith :: Screen -> Text -> Int -> IO ()
newLineWith s t w = withMVar s.lock \_ -> do
  cur <- readIORef s.current
  modifyIORef' s.lines' (|> cur)
  writeIORef s.current t
  writeIORef s.column w
  off <- readIORef s.offset
  if off > 0 then writeIORef s.offset (off + 1) else pure ()
  drawRegion s

scrollBy :: Screen -> Int -> IO ()
scrollBy s n = withMVar s.lock \_ -> do
  modifyIORef' s.offset (\o -> max 0 (o + n))
  drawRegion s

scrollTo :: Screen -> Int -> IO ()
scrollTo s n = withMVar s.lock \_ -> do
  writeIORef s.offset n
  drawRegion s

-- ===========================================================================
-- Writing the conversation
-- ===========================================================================

-- | Start a new block: a blank line, then a heading line, then the body
-- continues on the next line behind a bar in the given colour.
block :: Screen -> Int -> Text -> IO ()
block s colour heading = do
  first <- readIORef s.fresh
  writeIORef s.fresh False
  writeIORef s.barColour colour
  writeIORef s.word ""
  if first
    then withMVar s.lock \_ -> writeIORef s.current heading >> writeIORef s.column 0
    else newLineWith s "" 0 >> newLineWith s heading 0
  newLineWith s (fg colour "▌ ") 2

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
      | c == '\n' = flushWord >> barLine
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
            then barLine >> append s (fg colour w) (T.length w)
            else append s (fg colour w) (T.length w)
    space = do
      col <- readIORef s.column
      if col + 1 > maxCol then barLine else append s " " 1
    barLine = do
      bar <- readIORef s.barColour
      newLineWith s (fg bar "▌ ") 2

-- | Finish the current block: whatever word is still held is written, in
-- the colour of the text it came from.
endBlock :: Screen -> IO ()
endBlock s = do
  colour <- readIORef s.wordColour
  stream s colour " "

-- | A line under the current block, such as an answer's timing.
note :: Screen -> Text -> IO ()
note s t = do
  bar <- readIORef s.barColour
  newLineWith s (fg bar "▌ " <> t) (2 + visibleLength t)

-- ===========================================================================
-- Keys
-- ===========================================================================

-- | Read one line at the input row. Nothing means leave the chat: Esc,
-- Ctrl-D on an empty line, or Ctrl-C.
readInput :: Screen -> Text -> Text -> IO (Maybe Text)
readInput s prompt k = go ""
  where
    render buf =
      let room = s.width - visibleLength prompt - 2
          shown = if T.length buf > room then "…" <> T.takeEnd (room - 1) buf else buf
       in setBottom s (prompt <> fg cText shown) k
    go buf = do
      render buf
      r <- try (readChan s.keys) :: IO (Either AsyncException Key)
      case r of
        Left UserInterrupt -> pure Nothing
        Left e -> ioError (userError (show e))
        Right key -> case key of
          KEnter -> pure (Just buf)
          KEsc -> pure Nothing
          KEof | T.null buf -> pure Nothing
          KEof -> go buf
          KClear -> go ""
          KBack -> go (T.dropEnd 1 buf)
          KChar c -> go (T.snoc buf c)

-- | Read keys for as long as the chat is open. Scrolling acts here, at
-- once; everything else goes to the input line's queue.
readKeys :: Screen -> IO ()
readKeys s = loop
  where
    page = max 1 (regionHeight s - 2)
    loop = do
      r <- try getChar :: IO (Either IOException Char)
      case r of
        Left _ -> writeChan s.keys KEof
        Right c -> handle c >> loop
    handle c = case c of
      '\ESC' -> do
        more <- hWaitForInput stdin 30
        if not more then writeChan s.keys KEsc else escape
      '\n' -> writeChan s.keys KEnter
      '\r' -> writeChan s.keys KEnter
      '\EOT' -> writeChan s.keys KEof
      '\NAK' -> writeChan s.keys KClear
      '\DEL' -> writeChan s.keys KBack
      '\b' -> writeChan s.keys KBack
      _ | isControl c -> pure ()
      _ -> writeChan s.keys (KChar c)
    escape = do
      c <- getChar
      if c /= '[' && c /= 'O' then pure () else csi ""
    -- A control sequence: parameter characters, then one final character
    -- in the range @ to ~.
    csi acc = do
      c <- getChar
      if c >= '@' && c <= '~'
        then act (reverse acc) c
        else csi (c : acc)
    act params final = case (params, final) of
      ('<' : rest, m) | m == 'M' || m == 'm' -> wheel (takeWhile isDigit rest)
      ("5", '~') -> scrollBy s page
      ("6", '~') -> scrollBy s (negate page)
      ("", 'A') -> scrollBy s 1
      ("", 'B') -> scrollBy s (-1)
      ("", 'H') -> scrollTo s maxBound
      ("1", '~') -> scrollTo s maxBound
      ("", 'F') -> scrollTo s 0
      ("4", '~') -> scrollTo s 0
      _ -> pure ()
    wheel button = case button of
      "64" -> scrollBy s 3
      "65" -> scrollBy s (-3)
      _ -> pure ()