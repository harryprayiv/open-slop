-- | What ingest leaves out of the index, and why.
--
-- Two kinds of exclusion, checked in this order:
--
--   1. Paths. Glob patterns from the root's .llmqignore file and from
--      --exclude, in the shape of a .gitignore: a pattern with no slash
--      matches a file or directory name at any depth ("nerd.nix",
--      "*.json"), a pattern with a slash matches from the root
--      ("modules/home/glyphs/nerd.nix", "docs/old/**"), a trailing slash
--      matches directories only ("secrets/"), "*" and "?" match within one
--      path segment and "**" matches any number of segments. Blank lines
--      and lines starting with # are ignored. There is no negation.
--      An excluded directory is not walked into.
--
--   2. Content. A file whose text is a secret is never indexed, whatever
--      the patterns say: sops-encrypted files (their values are
--      ENC[AES256_GCM,...]) and PEM private keys. On 2026-10-16 the first
--      ingest of neoblade-config put secrets/blade.yaml, oracle.yaml and
--      winsmuth.yaml into the index as 16 chunks of ciphertext. The
--      ciphertext gave no answer anything, and an index is no place for a
--      secret even encrypted. Checking the content rather than a path
--      means a secret in a directory nobody thought to list is still
--      caught.
--
-- A file that is excluded and was indexed by an earlier run is removed at
-- the end of the run, like a file that was deleted.
module OpenSlop.Rag.Exclude
  ( Pattern
  , parsePatterns
  , ignoreFile
  , readIgnoreFile
  , excluded
  , secretKind
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as B
import Data.List (tails)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.FilePath ((</>))

data Pattern = Pattern
  { anchored :: Bool
  -- ^ matched against the whole path from the root, not just the name
  , dirOnly :: Bool
  , segments :: [Text]
  }
  deriving stock (Eq, Show)

-- | The patterns in a .llmqignore's text, or given on the command line.
parsePatterns :: [Text] -> [Pattern]
parsePatterns = concatMap one
  where
    one raw =
      let t = T.strip raw
       in if T.null t || "#" `T.isPrefixOf` t
            then []
            else
              let dirOnly = "/" `T.isSuffixOf` t
                  body = T.dropAround (== '/') t
                  segments = filter (not . T.null) (T.splitOn "/" body)
                  anchored = "/" `T.isInfixOf` body || "/" `T.isPrefixOf` t || length segments > 1
               in [Pattern {anchored, dirOnly, segments} | not (null segments)]

ignoreFile :: FilePath
ignoreFile = ".llmqignore"

-- | The root's .llmqignore, or no patterns when there is none.
readIgnoreFile :: FilePath -> IO [Pattern]
readIgnoreFile root = do
  r <- try @IOException (TIO.readFile (root </> ignoreFile))
  pure (either (const []) (parsePatterns . T.lines) r)

-- | Whether a path, relative to the root and split into segments, is
-- excluded. The flag says whether it is a directory.
excluded :: [Pattern] -> [Text] -> Bool -> Bool
excluded ps path isDir = any matches ps
  where
    matches p
      | p.dirOnly && not isDir = False
      | p.anchored = segs p.segments path
      | otherwise = case (p.segments, reverse path) of
          ([s], name : _) -> glob s name
          _ -> False

-- | Segment patterns against path segments, "**" taking any number.
segs :: [Text] -> [Text] -> Bool
segs [] [] = True
segs ("**" : ps) xs = any (segs ps) (tails xs)
segs (p : ps) (x : xs) = glob p x && segs ps xs
segs _ _ = False

-- | One segment: "*" any run of characters, "?" one character.
glob :: Text -> Text -> Bool
glob p s = go (T.unpack p) (T.unpack s)
  where
    go [] [] = True
    go ('*' : ps) xs = any (go ps) (tails xs)
    go ('?' : ps) (_ : xs) = go ps xs
    go (c : ps) (x : xs) = c == x && go ps xs
    go _ _ = False

-- | Why a file's content is a secret, when it is one.
--
-- Each kind is recognised by its marker followed by the shape of a real
-- value, not by the marker alone: an encrypted sops value has base64 data
-- and then ",iv:", a private key's header line is followed by a line of
-- base64, and an age key's prefix by its bech32 body. The markers alone
-- appear in code and notes that mention them, this module among them, and
-- matching on the marker alone left those files out of the index.
secretKind :: B.ByteString -> Maybe Text
secretKind raw
  | after "ENC[AES256_GCM,data:" sopsValue = Just "sops-encrypted"
  | after "PRIVATE KEY-----" pemBody = Just "a private key"
  | after "AGE-SECRET-KEY-1" ageBody = Just "an age secret key"
  | otherwise = Nothing
  where
    after needle ok = any ok (rests needle raw)
    rests needle s = case B.breakSubstring needle s of
      (_, r)
        | B.null r -> []
        | otherwise -> let rest = B.drop (B.length needle) r in rest : rests needle rest
    sopsValue r =
      let (d, more) = B.span base64 r
       in B.length d >= 4 && ",iv:" `B.isPrefixOf` more
    pemBody r =
      let (breaks, body) = B.span (\w -> w == 10 || w == 13) r
       in not (B.null breaks) && B.length (B.takeWhile base64 body) >= 40
    ageBody r = B.length (B.takeWhile bech32 r) >= 50
    base64 w = alnum w || w == 43 || w == 47 || w == 61
    bech32 w = (w >= 48 && w <= 57) || (w >= 65 && w <= 90)
    alnum w = (w >= 48 && w <= 57) || (w >= 65 && w <= 90) || (w >= 97 && w <= 122)