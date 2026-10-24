-- | The one directory an agent may touch, and the edits it may make there.
--
-- A 'Workspace' is a canonical directory. Every path a model names is
-- resolved against it by 'resolve', which refuses an absolute path, a path
-- that climbs out with "..", anything inside .git, tricorder's
-- configuration (its hooks are shell commands), and a path whose real
-- location after following symbolic links is outside the root. Reads and
-- writes take the resolved path, so there is no way to reach a file the
-- check did not pass.
--
-- Every link along the path is followed, the last one included, whether
-- or not its target exists. Until 2026-10-24 the check canonicalised the
-- nearest part of the path that exists, and doesPathExist is False for a
-- link whose target is missing, so a dangling link inside the project
-- anchored on its own directory and passed. Writing through it created its
-- target outside the project (probe O2). A repository can ship such a link.
--
-- This confines what the model reads and writes. It does not confine what
-- the build runs: compiling the project runs its Template Haskell and any
-- custom Setup, and tricorder runs its test suites, and the model wrote
-- some of that code. A task from someone you do not trust needs the run
-- itself in a sandbox.
--
-- llmq-agent makes the workspace a git worktree on a branch of its own, so
-- the user's checkout is never written to; see app/llmq-agent/Git.hs.
module OpenSlop.Agent.Workspace
  ( Workspace
  , workspaceRoot
  , openWorkspace
  , resolve
  , relativeTo
  , readText
  , writeText
  , listDirectory'
  , replaceOnce
  , numbered
  ) where

import Control.Exception (IOException, try)
import Control.Monad (join)
import Data.ByteString qualified as B
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Numeric.Natural (Natural)
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , getSymbolicLinkTarget
  , listDirectory
  , pathIsSymbolicLink
  )
import System.FilePath (isAbsolute, joinPath, makeRelative, splitDirectories, takeDirectory, (</>))

newtype Workspace = Workspace FilePath

workspaceRoot :: Workspace -> FilePath
workspaceRoot (Workspace r) = r

openWorkspace :: FilePath -> IO (Either Text Workspace)
openWorkspace dir = do
  ok <- doesDirectoryExist dir
  if ok
    then Right . Workspace <$> canonicalizePath dir
    else pure (Left (T.pack dir <> " is not a directory"))

-- | A path the model gave, as a real path under the root, or why not.
resolve :: Workspace -> Text -> IO (Either Text FilePath)
resolve (Workspace root) given
  | T.null p = pure (Right root)
  | isAbsolute (T.unpack p) = pure (Left (p <> " is absolute; give paths relative to the project root"))
  | ".." `elem` parts = pure (Left (p <> " climbs out of the project with .."))
  | take 1 parts == [".git"] = pure (Left (p <> " is inside .git, which is not for editing"))
  | takeFileName' parts == ".tricorder.yaml" = pure (Left (p <> " configures tricorder, whose hooks are shell commands; it is not for the model to change"))
  | otherwise = do
      let target = root </> joinPath parts
      real <- realLocation root parts
      pure case real of
        Left why -> Left (p <> ": " <> why)
        Right r
          | r == root || (root <> "/") `isPrefixOf` r -> Right target
          | otherwise -> Left (p <> " leads outside the project through a symbolic link")
  where
    p = T.strip given
    parts = filter (`notElem` ["", "."]) (splitDirectories (T.unpack p))
    takeFileName' ps = if null ps then "" else last ps

-- | Where a path really leads: the components are taken one at a time from
-- a real directory, and each one that is a symbolic link is replaced by its
-- target, read with getSymbolicLinkTarget, so a link whose target does not
-- exist is followed like any other. A component that does not exist ends
-- the following, since nothing below it can be a link. At most 40 links are
-- followed, as the kernel allows.
realLocation :: FilePath -> [FilePath] -> IO (Either Text FilePath)
realLocation = go (40 :: Int)
  where
    go _ cur [] = pure (Right cur)
    go hops cur (c : cs)
      | c == "." = go hops cur cs
      | c == ".." = go hops (takeDirectory cur) cs
      | otherwise = do
          let next = cur </> c
          link <- either (const False) id <$> try @IOException (pathIsSymbolicLink next)
          if not link
            then go hops next cs
            else
              if hops <= 0
                then pure (Left "too many symbolic links")
                else do
                  t <- try @IOException (getSymbolicLinkTarget next)
                  join <$> traverse (follow hops cur cs) (either (Left . T.pack . show) Right t)
    follow hops cur cs t
      | isAbsolute t = go (hops - 1) "/" (drop 1 (splitDirectories t) <> cs)
      | otherwise = go (hops - 1) cur (splitDirectories t <> cs)

relativeTo :: Workspace -> FilePath -> Text
relativeTo (Workspace root) f = T.pack (makeRelative root f)

-- | A file's text, decoded leniently so a stray byte does not stop a read.
readText :: FilePath -> IO (Either Text Text)
readText f = do
  r <- try @IOException (B.readFile f)
  pure case r of
    Left e -> Left (T.pack (show e))
    Right b
      | B.elem 0 (B.take 8192 b) -> Left "this is a binary file"
      | otherwise -> Right (TE.decodeUtf8With TE.lenientDecode b)

writeText :: FilePath -> Text -> IO (Either Text ())
writeText f t = do
  r <- try @IOException do
    createDirectoryIfMissing True (takeDirectory f)
    B.writeFile f (TE.encodeUtf8 t)
  pure (either (Left . T.pack . show) Right r)

-- | Entries directly under a directory, directories marked with a slash,
-- with .git and build output left out.
listDirectory' :: FilePath -> IO (Either Text [Text])
listDirectory' d = do
  r <- try @IOException (listDirectory d)
  case r of
    Left e -> pure (Left (T.pack (show e)))
    Right names -> do
      let shown = filter (`notElem` [".git", "dist-newstyle", ".direnv", ".stack-work", "node_modules", ".spago", "output"]) (sort names)
      Right <$> traverse mark shown
  where
    mark n = do
      isDir <- doesDirectoryExist (d </> n)
      pure (T.pack n <> (if isDir then "/" else ""))

-- | Replace the single occurrence of a text. When it is not there exactly,
-- say whether it is there apart from indentation and spacing, which is the
-- usual reason a model's copy does not match.
replaceOnce :: Text -> Text -> Text -> Either Text Text
replaceOnce old new content
  | T.null old = Left "replace is empty; to create or replace a whole file use WriteFile"
  | otherwise = case T.count old content of
      1 -> let (before, after) = T.breakOn old content in Right (before <> new <> T.drop (T.length old) after)
      0
        | loose old `T.isInfixOf` loose content ->
            Left "the text to replace is not in the file exactly, but it is there with different indentation or spacing; read the lines again and copy them exactly"
        | otherwise -> Left "the text to replace is not in the file; read the file again and copy the text exactly"
      n -> Left ("the text to replace occurs " <> T.pack (show n) <> " times; include more of the surrounding lines so it occurs once")
  where
    loose = T.unwords . T.words

-- | Lines of a file, numbered, from first to last, in at most the given
-- characters. A range that does not fit is cut at a line, and the reader is
-- told where to continue.
numbered :: Int -> Maybe Natural -> Maybe Natural -> Text -> Text
numbered room first lastL content
  | total == 0 = "(the file is empty)"
  | from > total = "the file has " <> tshow total <> " lines; line " <> tshow from <> " is past the end"
  | otherwise = header <> T.intercalate "\n" shown <> footer
  where
    ls = T.lines content
    total = length ls
    from = maybe 1 (max 1 . fromIntegral) first
    to = maybe total (min total . fromIntegral) lastL
    width = length (show to)
    render (n, l) = T.justifyRight width ' ' (tshow n) <> "| " <> l
    candidates = map render (take (to - from + 1) (drop (from - 1) (zip [1 :: Int ..] ls)))
    header = "lines " <> tshow from <> "-" <> tshow to <> " of " <> tshow total <> "\n"
    (shown, used) = fit (room - T.length header - 120) candidates
    stopped = from + used - 1
    footer
      | stopped < to = "\n[cut at line " <> tshow stopped <> " to fit; read from line " <> tshow (stopped + 1) <> " to see more]"
      | otherwise = ""
    fit _ [] = ([], 0)
    fit left (x : xs)
      | T.length x + 1 <= left = let (ys, k) = fit (left - T.length x - 1) xs in (x : ys, k + 1)
      | otherwise = ([], 0 :: Int)

tshow :: (Show a) => a -> Text
tshow = T.pack . show