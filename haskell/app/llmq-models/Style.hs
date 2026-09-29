-- | Colours, measured text, and terminal control.
--
-- Part of llmq-models; Main describes the program.
--
-- 256-colour escapes, which every terminal in use supports. All widths are
-- computed on the text before it is coloured, and every finished line goes
-- through `clip`, which counts only visible characters, so an escape code
-- never pushes a line past the edge.
module Style
  ( fg
  , bg
  , bold
  , rev
  , cGreen
  , cYellow
  , cRed
  , cBlue
  , cMagenta
  , cCyan
  , cGrey
  , cMuted
  , cText
  , cAccent
  , cPanel
  , cSel
  , cBar
  , feelColour
  , backendColour
  , clip
  , visibleLength
  , padTo
  , padL
  , gauge
  , fmt
  , showParams
  , duration
  , wrap
  , enterScreen
  , leaveScreen
  , termSize
  ) where

import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Models (Feel (..))
import System.IO
import System.Process (readCreateProcess, shell)
import Text.Printf (printf)
import Text.Read (readMaybe)


fg, bg :: Int -> Text -> Text
fg c t = "\ESC[38;5;" <> T.pack (show c) <> "m" <> t <> "\ESC[39m"
bg c t = "\ESC[48;5;" <> T.pack (show c) <> "m" <> t <> "\ESC[49m"

bold, rev :: Text -> Text
bold t = "\ESC[1m" <> t <> "\ESC[22m"
rev t = "\ESC[7m" <> t <> "\ESC[27m"

-- Palette.
cGreen, cYellow, cRed, cBlue, cMagenta, cCyan, cGrey, cMuted, cText, cAccent, cPanel, cSel, cBar :: Int
cGreen = 114
cYellow = 221
cRed = 203
cBlue = 75
cMagenta = 176
cCyan = 80
cGrey = 244
cMuted = 240
cText = 252
cAccent = 111
cPanel = 236
cSel = 238
cBar = 24

feelColour :: Feel -> Int
feelColour = \case
  Conversational -> cGreen
  Readable -> cYellow
  Batch -> cRed
  Unmeasured -> cGrey

backendColour :: Text -> Int
backendColour = \case
  "cpu" -> cBlue
  "hailo" -> cMagenta
  "llamacpp" -> cCyan
  _ -> cGrey

-- | Cut a line to n visible characters, leaving escape sequences intact and
-- resetting all attributes at the end.
clip :: Int -> Text -> Text
clip n t = go n t <> "\ESC[0m"
  where
    go k s
      | T.null s = ""
      | T.head s == '\ESC' =
          let (esc, rest) = T.span (not . isAlphaEnd) (T.drop 1 s)
           in "\ESC" <> esc <> T.take 1 rest <> go k (T.drop 1 rest)
      | k <= 0 = go 0 (T.dropWhile (/= '\ESC') s)
      | otherwise = T.take 1 s <> go (k - 1) (T.drop 1 s)
    isAlphaEnd c = c `elem` ("mABCDHJKhl" :: String)

visibleLength :: Text -> Int
visibleLength = go 0
  where
    go k s
      | T.null s = k
      | T.head s == '\ESC' = go k (T.drop 1 (T.dropWhile (`notElem` ("mABCDHJKhl" :: String)) (T.drop 1 s)))
      | otherwise = go (k + 1) (T.drop 1 s)

padTo :: Int -> Text -> Text
padTo n t = t <> T.replicate (max 0 (n - visibleLength t)) " "

padL :: Int -> Text -> Text
padL n t = T.replicate (max 0 (n - visibleLength t)) " " <> t

-- | A horizontal gauge of `w` cells for a fraction, in eighths.
gauge :: Int -> Double -> Text
gauge w frac =
  let eighths = max 0 (min (w * 8) (round (frac * fromIntegral (w * 8)))) :: Int
      (full, part) = eighths `divMod` 8
      partial = if part == 0 then "" else T.singleton ("▏▎▍▌▋▊▉" !! (part - 1))
      used = full + (if part == 0 then 0 else 1)
   in T.replicate full "█" <> partial <> T.replicate (w - used) " "

fmt :: String -> Double -> Text
fmt f x = T.pack (printf f x)

showParams :: (Double, Bool) -> Text
showParams (p, exact) = (if exact then "" else "~") <> (if p >= 10 then fmt "%.0f" p else fmt "%.1f" p) <> "B"

duration :: Double -> Text
duration s
  | s < 90 = T.pack (show (round s :: Int)) <> " s"
  | s < 5400 = fmt "%.1f" (s / 60) <> " min"
  | otherwise = fmt "%.1f" (s / 3600) <> " h"

wrap :: Int -> Text -> [Text]
wrap width t = go (T.words (T.map (\c -> if isSpace c then ' ' else c) t))
  where
    go [] = []
    go ws = let (l, rest) = fill ws 0 [] in T.unwords l : go rest
    fill [] _ acc = (reverse acc, [])
    fill (w : ws) n acc
      | null acc = fill ws (T.length w) [w]
      | n + 1 + T.length w > width = (reverse acc, w : ws)
      | otherwise = fill ws (n + 1 + T.length w) (w : acc)


-- | Raw keys, no echo, the alternate screen and a hidden cursor.
enterScreen :: IO ()
enterScreen = do
  hSetBuffering stdin NoBuffering
  hSetEcho stdin False
  hSetBuffering stdout (BlockBuffering Nothing)
  TIO.putStr "\ESC[?1049h\ESC[?25l"
  hFlush stdout

-- | Back to the normal screen, a visible cursor and line input: where a
-- question is typed and its answer streams.
leaveScreen :: IO ()
leaveScreen = do
  TIO.putStr "\ESC[0m\ESC[?25h\ESC[?1049l"
  hFlush stdout
  hSetBuffering stdout NoBuffering
  hSetBuffering stdin LineBuffering
  hSetEcho stdin True

-- | Rows and columns of the controlling terminal, from stty. Falls back to
-- 24 by 100 when there is no terminal to ask, or when it reports zero.
termSize :: IO (Int, Int)
termSize = do
  out <- readCreateProcess (shell "stty size < /dev/tty 2>/dev/null || true") ""
  pure case map readMaybe (words out) of
    [Just h, Just w] | h > 0 && w > 0 -> (h, w)
    _ -> (24, 100)
