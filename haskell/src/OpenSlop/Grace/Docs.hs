-- | The result type of the reference-docs stage, and what is done with it.
--
-- This is the shape a Grace stage promises to produce. The Grace file's own
-- annotation has to match it, or the file fails to load, which is the whole
-- point of running the pipeline through Grace: the model's output is
-- constrained to a schema by the server, decoded against this type by Grace,
-- and checked for coverage here. Nothing downstream parses prose.
--
-- The field naming the file is `path`, not `file`. Grace's lexer treats
-- `file` as a URI scheme, the same as `http` and `env`, so a record label
-- `file:` starts an import and the stage fails to parse at that token.
--
-- The Grace instances are NOT here: this module is in the library, which
-- does not depend on Grace, so that the rendering and the coverage check can
-- be tested without building Grace. The orphan instances live beside the
-- loader in app/llmq-grace.
module OpenSlop.Grace.Docs
  ( FileDoc (..)
  , Docs (..)
  , renderDocs
  , missingFiles
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | One file's documentation. Every field is a list of plain sentences
-- rather than Markdown, so the rendering here decides the shape of the
-- document and the model only supplies facts.
data FileDoc = FileDoc
  { path :: Text
  -- ^ the path as the part's marker gives it
  , purpose :: Text
  , interface :: [Text]
  , behaviour :: [Text]
  , reasoning :: [Text]
  -- ^ reasons the file's own comments give; empty when it gives none
  , openQuestions :: [Text]
  -- ^ only what the text marks; empty is the common answer
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype Docs = Docs {files :: [FileDoc]}
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Files that begin in this part and have no entry in the answer. The
-- typed replacement for matching headings in prose: the model either
-- returned a record for a file or it did not, and a trailing backtick
-- cannot confuse it.
missingFiles :: [Text] -> Docs -> [Text]
missingFiles starts (Docs fs) = filter (not . covered) starts
  where
    named = map (\f -> T.strip f.path) fs
    covered s =
      let base = T.takeWhileEnd (/= '/') s
       in any (\n -> n == s || n == base || T.isSuffixOf base n) named

-- | The document for one part. The headings, the order of the sections and
-- the words "None marked" are chosen here, once, rather than asked of the
-- model on every request.
renderDocs :: Docs -> Text
renderDocs (Docs fs) = T.intercalate "\n" (map one fs)
  where
    one f =
      T.unlines
        ( ["## " <> f.path, "", f.purpose, ""]
            <> section "Interface" f.interface
            <> section "Behaviour" f.behaviour
            <> section "Reasoning" f.reasoning
            <> questions f.openQuestions
        )
    section title items
      | null items = ["### " <> title, "", "None stated in the text.", ""]
      | otherwise = ["### " <> title, ""] <> map ("- " <>) items <> [""]
    questions items
      | null items = ["### Open questions", "", "None marked.", ""]
      | otherwise = ["### Open questions", ""] <> map ("- " <>) items <> [""]