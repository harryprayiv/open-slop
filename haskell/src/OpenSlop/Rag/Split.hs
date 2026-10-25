-- | Cut a document into retrieval chunks.
--
-- A document is split 'Headed' or 'Flat', and the caller says which.
--
-- 'Headed' is for markdown-shaped text: markdown itself, and what pandoc
-- and pdftotext produce for the converted formats. Markdown ATX headings
-- outside fenced code start a new section, and the heading path
-- ("Install > NixOS") goes with every chunk cut from that section, both
-- into the text that is embedded and into the citation.
--
-- 'Flat' is for source code and plain text, where a line starting with
-- "# " is a comment in Nix, shell, Python, YAML and TOML, not a heading.
-- Until 2026-10-16 every document was split as markdown, so a Nix comment
-- became a chunk's heading: modules/system/cache.nix was cited under
-- "the cautionary example of a role demanding a key that signs nothing.",
-- one sentence of a comment, and that sentence was embedded with the chunk
-- and sent to the reranker as if it named the section. A flat document has
-- one section with no heading.
--
-- 'Declared' is for Allium specifications. Each top-level declaration
-- (an entity, a rule, a surface, an enum and so on) starts a section whose
-- heading is the declaration, "rule CheckoutCompletes", under the banner
-- comment it sits beneath ("Rules"), and the comment lines directly above
-- a declaration go with it. Until 2026-10-25 a specification was split
-- 'Flat', so a chunk carried no heading and could begin halfway through
-- one rule and end in the next; neither the embedding nor the citation
-- said which rule it was.
--
-- Whichever way, inside a section blank-line separated blocks are packed up to
-- the target size; a block larger than the target is cut at line
-- boundaries, and a line larger than the target is cut by characters.
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
  , Structure (..)
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

-- | Whether a document's headings are markdown headings.
data Structure
  = Headed
  -- ^ markdown-shaped: ATX headings outside code fences open sections
  | Flat
  -- ^ code or plain text: no line is a heading
  | Declared
  -- ^ an Allium specification: each top-level declaration opens a section
  deriving stock (Eq, Show)

split :: SplitConfig -> Structure -> Text -> [Piece]
split cfg0 structure input =
  zipWith
    (\i p -> p {ordinal = i})
    [0 ..]
    (concatMap (packSection cfg) grouped)
  where
    grouped = case structure of
      Headed -> sections numbered
      Flat -> [Section {path = [], slines = numbered} | not (null numbered)]
      Declared -> declarations numbered
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

-- | Group an Allium specification's lines into sections, one per top-level
-- declaration, each under the banner it follows. A banner is a comment line
-- between two ruler lines (a comment of dashes only):
--
-- > ------------------------------
-- > -- Rules
-- > ------------------------------
--
-- and it opens a section of its own, headed by its title, which holds the
-- banner and whatever comes before the first declaration under it. The
-- comment lines directly above a declaration, with no blank line between,
-- open the declaration's section with it, since they describe it.
declarations :: [Line] -> [Section]
declarations = go [] [] [] []
  where
    go _ path acc out [] = reverse (close path acc out)
    go banner path acc out (l : ls)
      | Just title <- bannerTitle acc l ls =
          -- the ruler above the title moves into the banner's section
          let rulerAbove = take 1 acc
           in go [title] [title] (l : rulerAbove) (close path (drop 1 acc) out) ls
      | Just name <- declaration l.txt =
          let (described, before) = span (\x -> isComment x.txt && not (isRuler x.txt)) acc
           in go banner (banner <> [name]) (l : described) (close path before out) ls
      | otherwise = go banner path (l : acc) out ls
    close _ [] out = out
    close path acc out = Section {path, slines = reverse acc} : out
    bannerTitle acc l ls = case (acc, ls) of
      (above : _, below : _)
        | isRuler above.txt, isRuler below.txt, isComment l.txt, not (isRuler l.txt) ->
            let t = T.strip (T.drop 2 l.txt) in if T.null t then Nothing else Just t
      _ -> Nothing

isComment :: Text -> Bool
isComment = T.isPrefixOf "--"

isRuler :: Text -> Bool
isRuler t = let s = T.strip t in T.length s >= 4 && T.all (== '-') s

-- | A top-level Allium declaration, as its keyword and name: "rule
-- CheckoutCompletes". Only at the start of a line: a declaration inside
-- another is part of it.
declaration :: Text -> Maybe Text
declaration t = case T.words t of
  (kw : rest) | kw `elem` declarationKeywords, not (T.null (T.take 1 t)), T.take 1 t /= " " ->
    case rest of
      (n : _) | let name = T.takeWhile (\c -> c /= '{' && c /= '(' && c /= ':') n, not (T.null name) -> Just (kw <> " " <> name)
      _ -> Just kw
  _ -> Nothing

declarationKeywords :: [Text]
declarationKeywords =
  [ "actor"
  , "config"
  , "contract"
  , "default"
  , "deferred"
  , "entity"
  , "enum"
  , "external"
  , "given"
  , "invariant"
  , "module"
  , "open"
  , "rule"
  , "surface"
  , "use"
  , "value"
  ]

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