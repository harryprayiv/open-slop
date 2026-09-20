-- | Cut input into parts that fit one request.
--
-- The same rules as the awk chunker it replaces, so a job's parts do not
-- change when the client does:
--
--   1. cut before a catsrc "Start of" marker, if the part is a quarter full
--   2. cut before a line that follows a blank line, if the part is half full
--   3. cut before whichever line would overflow
--
-- A single line longer than the budget is cut into pieces of budget-1 bytes.
--
-- Lengths are UTF-8 byte lengths. Bytes over-count characters, which is the
-- safe direction for a budget. A piece cut (rule 3 on an oversized line) can
-- land inside a multibyte character; the piece is then re-decoded leniently,
-- so the broken sequence becomes U+FFFD in that part.
module OpenSlop.Chunk
  ( Part (..)
  , Mode (..)
  , chunk
  , chunkWith
  , reassemble
  , fileMarker
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.List (foldl')
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE

-- | One part of a job's input.
data Part = Part
  { index :: Int
  -- ^ 1-based
  , body :: Text
  , bytes :: Int
  , continues :: Maybe Text
  -- ^ the file this part begins partway through, if any
  , starts :: [Text]
  -- ^ files whose "Start of" marker is in this part
  }
  deriving stock (Show, Eq)

commentLeads :: [ByteString]
commentLeads = ["#", "--", "//", ";", "%", "<!--", "/*", "'", "REM", "(*", "{-", "###"]

trailers :: [ByteString]
trailers = [" -->", " */", " *)", " -}", " ###"]

-- | The file a catsrc marker line names, when the line is one.
fileMarker :: ByteString -> ByteString -> Maybe Text
fileMarker verb line = go commentLeads
  where
    go [] = Nothing
    go (lead : rest)
      | Just after <- B.stripPrefix (lead <> " " <> verb <> " of ") line =
          Just (TE.decodeUtf8With TE.lenientDecode (stripTrailer after))
      | otherwise = go rest
    stripTrailer s = foldl' (\acc t -> maybe acc id (B.stripSuffix t acc)) s trailers

isStart, isEnd :: ByteString -> Bool
isStart = isJust . fileMarker "Start"
isEnd = isJust . fileMarker "End"

isBlank :: ByteString -> Bool
isBlank = BC.all (`elem` (" \t\r" :: String))

data Line = Line
  { text :: ByteString
  , len :: Int
  -- ^ bytes including the newline
  , strong :: Bool
  , weak :: Bool
  }

-- | How parts are cut.
data Mode
  = Packed
  -- ^ fill each part to the budget, preferring file boundaries
  | PerFile
  -- ^ every "Start of" marker begins a new part, however little is in the
  -- part before it; an oversized file still splits at the budget. Measured
  -- 2026-09-20: qwen2.5-coder:7b given four files in one part documented
  -- the first and stopped, with or without an instruction not to. One file
  -- per part is the structural answer.
  deriving stock (Show, Eq)

-- | Cut @input@ into parts of at most @budget@ bytes, packed.
chunk :: Int -> Text -> [Part]
chunk = chunkWith Packed

chunkWith :: Mode -> Int -> Text -> [Part]
chunkWith mode budget input
  | budget < 2 = error "OpenSlop.Chunk.chunk: budget must be at least 2"
  | otherwise = go 1 Nothing linesV
  where
    raw = BC.lines (TE.encodeUtf8 input)
    linesV = zipWith mk (Nothing : map Just raw) raw
    mk prev l =
      Line
        { text = l
        , len = B.length l + 1
        , strong = isStart l
        , weak = maybe False isBlank prev
        }

    go :: Int -> Maybe Text -> [Line] -> [Part]
    go _ _ [] = []
    go n open (l : rest)
      | l.len > budget =
          let pieces = splitLong l.text
              (parts, n', open') = emitPieces n open pieces
           in parts ++ go n' open' rest
    go n open ls =
      let (taken, fill, remaining) = takeFit 0 [] ls
       in case remaining of
            [] -> [emit n open taken]
            _ ->
              let cutAt = bestCut fill taken remaining
                  (here, later) = splitAt cutAt taken
                  part = emit n open here
                  open' = openAfter open here
               in part : go (n + 1) open' (map fst later ++ remaining)

    -- Take lines while they fit, returning them with running fills. In
    -- PerFile mode a marker line also ends the run when it is not the first
    -- line taken, so it starts the next part.
    takeFit :: Int -> [(Line, Int)] -> [Line] -> ([(Line, Int)], Int, [Line])
    takeFit fill acc [] = (reverse acc, fill, [])
    takeFit fill acc (l : ls)
      | mode == PerFile && l.strong && not (null acc) = (reverse acc, fill, l : ls)
      | fill + l.len <= budget = takeFit (fill + l.len) ((l, fill + l.len) : acc) ls
      | otherwise = (reverse acc, fill, l : ls)

    -- Index into @taken@ before which to cut. Looks from the overflowing line
    -- backwards, first for a strong cut, then a weak one, else takes it all.
    bestCut :: Int -> [(Line, Int)] -> [Line] -> Int
    bestCut _ taken (next : _)
      | mode == PerFile && next.strong = length taken
    bestCut _ taken (next : _) =
      let n = length taken
          candidates pr thresh =
            [ i
            | i <- reverse [1 .. n]
            , let (l, _) = taken !! min (n - 1) i
            , let upto = snd (taken !! (i - 1))
            , (if i == n then pr next else pr l)
            , upto * thresh >= budget
            ]
       in case candidates (.strong) 4 of
            (i : _) -> i
            [] -> case candidates (.weak) 2 of
              (i : _) -> i
              [] -> n
    bestCut _ taken [] = length taken

    emit :: Int -> Maybe Text -> [(Line, Int)] -> Part
    emit n open taken =
      let ls = map fst taken
          firstStrong = case ls of
            (l : _) -> l.strong
            [] -> False
          bodyBs = B.intercalate "\n" (map (.text) ls) <> "\n"
       in Part
            { index = n
            , body = TE.decodeUtf8With TE.lenientDecode bodyBs
            , bytes = sum (map (.len) ls)
            , continues = if firstStrong then Nothing else open
            , starts = [f | l <- ls, Just f <- [fileMarker "Start" l.text]]
            }

    openAfter :: Maybe Text -> [(Line, Int)] -> Maybe Text
    openAfter = foldl' step
      where
        step o (l, _)
          | Just f <- fileMarker "Start" l.text = Just f
          | isEnd l.text = Nothing
          | otherwise = o

    splitLong :: ByteString -> [ByteString]
    splitLong s
      | B.null s = []
      | otherwise = let (p, r) = B.splitAt (budget - 1) s in p : splitLong r

    emitPieces :: Int -> Maybe Text -> [ByteString] -> ([Part], Int, Maybe Text)
    emitPieces n open pieces =
      ( [ Part
            { index = n + i
            , body = TE.decodeUtf8With TE.lenientDecode (p <> "\n")
            , bytes = B.length p + 1
            , continues = open
            , starts = []
            }
        | (i, p) <- zip [0 ..] pieces
        ]
      , n + length pieces
      , open
      )

-- | Concatenating the bodies gives the input back, with a trailing newline
-- added if the input lacked one. The test suite checks this.
reassemble :: [Part] -> Text
reassemble = T.concat . map (.body)