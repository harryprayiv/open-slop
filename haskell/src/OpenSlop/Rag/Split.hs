-- | Cut a document into retrieval chunks.
--
-- Input is markdown-shaped text: markdown and org sources as converted by
-- pandoc, plain text, or source code. Markdown ATX headings outside fenced
-- code start a new section, and the heading path ("Install > NixOS") goes
-- with every chunk cut from that section, both into the text that is
-- embedded and into the citation. Inside a section, blank-line separated
-- blocks are packed up to the target size; a block larger than the target
-- is cut at line boundaries, and a line larger than the target is cut
-- by characters.
--
-- Every chunk records the 1-based line range it came from, in the text this
-- function was given. For a markdown, text or code source that is the file
-- itself. For a converted source (PDF, docx) it is the converted text, and
-- the page is carried separately by the caller.
--
-- Pure, and tested by property in test/Main.hs: chunks never exceed the
-- hard limit, and every non-blank input line lands in exactly one chunk.
module OpenSlop.Rag.Split
  ( Piece (..)
  , SplitConfig (..)
  , defaultSplit
  , split
  , embedText
  ) where

import Data.Text (Text)
import Data.Text qualified as T

data Piece = Piece
  { ordinal :: Int
  -- ^ 0-based, in document order
  , heading :: [Text]
  -- ^ the enclosing headings, outermost first
  , body :: Text
  , lineFrom :: Int
  , lineTo :: Int
  }
  deriving stock (Show, Eq)

data SplitConfig = SplitConfig
  { target :: Int
  -- ^ characters a chunk is packed up to
  , hardLimit :: Int
  -- ^ characters no chunk body exceeds; at least target
  }
  deriving stock (Show, Eq)

-- | About 400 tokens of English at 4 characters each: inside every embedding
-- model's window in the catalogue, and small enough that a handful of them
-- fit beside a question in a 4K answer window.
defaultSplit :: SplitConfig
defaultSplit = SplitConfig {target = 1600, hardLimit = 2400}

-- | What is embedded for a chunk: the heading path, then the body.
embedText :: Piece -> Text
embedText p
  | null p.heading = p.body
  | otherwise = T.intercalate " > " p.heading <> "\n\n" <> p.body

data Line = Line
  { no :: Int
  , txt :: Text
  }

data Section = Section
  { path :: [Text]
  , slines :: [Line]
  }

split :: SplitConfig -> Text -> [Piece]
split cfg0 input =
  zipWith
    (\i p -> p {ordinal = i})
    [0 ..]
    (concatMap (packSection cfg) (sections numbered))
  where
    cfg = cfg0 {hardLimit = max cfg0.target cfg0.hardLimit, target = max 1 cfg0.target}
    numbered = zipWith Line [1 ..] (T.lines (T.replace "\r\n" "\n" input))

-- | Group lines into sections at headings outside code fences. A heading
-- line belongs to the section it opens.
sections :: [Line] -> [Section]
sections = go [] False [] []
  where
    go path _ acc out [] = reverse (close path acc out)
    go path inFence acc out (l : ls)
      | isFence l.txt = go path (not inFence) (l : acc) out ls
      | not inFence, Just (level, title) <- atxHeading l.txt =
          let path' = take (level - 1) (path <> repeat "") <> [title]
              cleaned = filter (not . T.null) path'
           in go cleaned False [l] (close path acc out) ls
      | otherwise = go path inFence (l : acc) out ls
    close _ [] out = out
    close path acc out = Section {path, slines = reverse acc} : out

isFence :: Text -> Bool
isFence t = let s = T.stripStart t in "```" `T.isPrefixOf` s || "~~~" `T.isPrefixOf` s

atxHeading :: Text -> Maybe (Int, Text)
atxHeading t =
  let (hashes, rest) = T.span (== '#') t
      level = T.length hashes
   in if level >= 1 && level <= 6 && (T.null rest || T.head rest == ' ')
        then Just (level, T.strip (T.dropWhileEnd (== '#') (T.strip rest)))
        else Nothing

-- | Blocks are runs of non-blank lines.
blocks :: [Line] -> [[Line]]
blocks ls = case dropWhile blank ls of
  [] -> []
  rest -> let (b, after) = break blank rest in b : blocks after
  where
    blank l = T.null (T.strip l.txt)

packSection :: SplitConfig -> Section -> [Piece]
packSection cfg s = map toPiece (pack [] (concatMap (fitBlock cfg) (blocks s.slines)))
  where
    toPiece ls =
      Piece
        { ordinal = 0
        , heading = s.path
        , body = T.intercalate "\n" (map (.txt) ls)
        , lineFrom = (head ls).no
        , lineTo = (last ls).no
        }
    size = sum . map ((+ 1) . T.length . (.txt))
    pack cur [] = [reverse cur | not (null cur)]
    pack cur (b : bs)
      | null cur = pack (reverse b) bs
      | size cur + 1 + size b <= cfg.target = pack (reverse b <> blankAfter cur) bs
      | otherwise = reverse cur : pack [] (b : bs)
    -- keep the paragraph break between packed blocks without inventing a
    -- line number: the blank goes in as text on the previous line's number
    blankAfter cur = case cur of
      (l : rest) -> l {txt = l.txt <> "\n"} : rest
      [] -> []

-- | A block within the hard limit stays whole. A larger one is cut at line
-- boundaries into runs within the target, and a single overlong line is cut
-- by characters into hard-limit pieces that share its line number.
fitBlock :: SplitConfig -> [Line] -> [[Line]]
fitBlock cfg b
  | blockSize b <= cfg.hardLimit = [b]
  | otherwise = runs [] (concatMap cutLine b)
  where
    blockSize = sum . map ((+ 1) . T.length . (.txt))
    cutLine l
      | T.length l.txt <= cfg.hardLimit = [l]
      | otherwise = [Line l.no c | c <- T.chunksOf (cfg.hardLimit - 1) l.txt]
    runs cur [] = [reverse cur | not (null cur)]
    runs cur (l : ls)
      | null cur = runs [l] ls
      | blockSize cur + T.length l.txt + 1 <= cfg.target = runs (l : cur) ls
      | otherwise = reverse cur : runs [l] ls
