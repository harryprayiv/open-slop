-- | Files to text the splitter can cut.
--
-- Markdown, plain text and source code are read as they are, so a chunk's
-- line range is a line range in the file. Office, web and book formats go
-- through pandoc to GitHub markdown, so their headings survive as headings.
-- PDFs go through pdftotext, and each page becomes a "Page n" heading, so a
-- citation names the page.
--
-- An .allium file is a specification of what the code should do (rules,
-- invariants, and where the code differs from them), read as it is and
-- split at its top-level declarations, so each chunk is headed by the rule
-- or entity it holds; see "OpenSlop.Rag.Split".
--
-- A .chase bundle (from chase, the structural compressor for Haskell and
-- PureScript) is split per module: each "=== BEGIN path ===" line becomes a
-- heading naming the module's file, and each "=== END ... ===" line a blank
-- line, one line for one, so a chunk's line range is still a line range in
-- the bundle and its heading says which source file it summarises.
--
-- pandoc and pdftotext are found at $OPEN_SLOP_PANDOC and
-- $OPEN_SLOP_PDFTOTEXT, which the Nix wrapper sets to store paths, or on
-- PATH when those are unset.
module Extract
  ( Kind (..)
  , kindName
  , structureOf
  , classify
  , extract
  , skipDir
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import OpenSlop.Rag.Split (Structure (..))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeExtension, takeFileName)
import System.Process.Typed (proc, readProcess)

data Kind
  = Markdown
  | PlainText
  | Code
  | Converted Text
  -- ^ through pandoc, with pandoc's reader name
  | Pdf
  | Chase
  -- ^ a chase bundle: signatures, types and annotations, no bodies
  | Allium
  -- ^ an Allium specification of the code's intended behaviour
  deriving stock (Eq, Show)

kindName :: Kind -> Text
kindName = \case
  Markdown -> "markdown"
  PlainText -> "text"
  Code -> "code"
  Converted r -> "pandoc:" <> r
  Pdf -> "pdf"
  Chase -> "chase"
  Allium -> "allium"

-- | How a kind's text is split. Markdown and everything converted to it
-- has headings; in code and plain text a "# " line is a comment.
structureOf :: Kind -> Structure
structureOf = \case
  Markdown -> Headed
  Converted _ -> Headed
  Pdf -> Headed
  Chase -> Headed
  PlainText -> Flat
  Code -> Flat
  Allium -> Declared

classify :: FilePath -> Maybe Kind
classify path = case map toLower (takeExtension path) of
  e | e `elem` [".md", ".markdown"] -> Just Markdown
  e | e `elem` [".txt", ".text", ".log", ".csv", ".tsv"] -> Just PlainText
  ".org" -> Just (Converted "org")
  ".rst" -> Just (Converted "rst")
  ".docx" -> Just (Converted "docx")
  ".odt" -> Just (Converted "odt")
  ".epub" -> Just (Converted "epub")
  ".html" -> Just (Converted "html")
  ".htm" -> Just (Converted "html")
  ".rtf" -> Just (Converted "rtf")
  ".tex" -> Just (Converted "latex")
  ".pdf" -> Just Pdf
  ".chase" -> Just Chase
  ".allium" -> Just Allium
  e | e `elem` codeExtensions -> Just Code
  "" | takeFileName path `elem` ["README", "LICENSE", "Makefile", "Justfile"] -> Just PlainText
  _ -> Nothing

codeExtensions :: [String]
codeExtensions =
  [ ".hs", ".lhs", ".cabal", ".purs", ".dhall", ".nix", ".ffg", ".sql", ".sh", ".fish"
  , ".toml", ".yaml", ".yml", ".json", ".el", ".lua", ".c", ".h", ".rs", ".go"
  , ".py", ".js", ".ts", ".css", ".scss", ".java", ".kt", ".scala", ".ml", ".agda", ".lean", ".idr"
  ]

-- | Directories never walked into.
skipDir :: FilePath -> Bool
skipDir d =
  d `elem` [".git", ".direnv", "dist-newstyle", ".stack-work", "node_modules", ".spago"]
    || take 1 d == "."

tool :: String -> String -> IO FilePath
tool var fallback = maybe fallback id <$> lookupEnv var

lenient :: B.ByteString -> Text
lenient = TE.decodeUtf8With TE.lenientDecode

-- | The text of a file, or why it has none. Files with a NUL byte in the
-- first 8 KiB are refused as binary.
extract :: Kind -> FilePath -> B.ByteString -> IO (Either Text Text)
extract kind path raw = case kind of
  Pdf -> do
    exe <- tool "OPEN_SLOP_PDFTOTEXT" "pdftotext"
    run exe ["-enc", "UTF-8", path, "-"] >>= pure . fmap pages
  Converted reader -> do
    exe <- tool "OPEN_SLOP_PANDOC" "pandoc"
    run exe ["--from", T.unpack reader, "--to", "gfm", "--wrap=none", path]
  _
    | B.elem 0 (B.take 8192 raw) -> pure (Left "binary content")
    | kind == Chase -> pure (Right (chaseModules (lenient raw)))
    | otherwise -> pure (Right (lenient raw))
  where
    run exe args = do
      r <- try @SomeException (readProcess (proc exe args))
      pure case r of
        Left e -> Left (T.pack exe <> ": " <> T.pack (takeWhile (/= '\n') (show e)))
        Right (ExitSuccess, out, _) -> Right (lenient (BL.toStrict out))
        Right (ExitFailure n, _, err) ->
          Left (T.pack exe <> " exited " <> T.pack (show n) <> ": " <> T.take 300 (lenient (BL.toStrict err)))
    chaseModules = T.intercalate "\n" . map marker . T.splitOn "\n"
    marker line
      | Just p <- between "=== BEGIN " line = "# " <> p
      | Just _ <- between "=== END " line = ""
      | otherwise = line
    between start line = do
      rest <- T.stripPrefix start (T.stripEnd line)
      T.strip <$> T.stripSuffix "===" rest
    pages t =
      T.intercalate "\n" $
        [ "# Page " <> T.pack (show n) <> "\n\n" <> p
        | (n, p) <- zip [1 :: Int ..] (T.splitOn "\f" t)
        , not (T.null (T.strip p))
        ]