-- | What an agent may do, as a closed type.
--
-- The model never calls a tool by name in free text. Each turn it returns
-- one 'Decision': a short plan and one 'Action', and the server is made to
-- produce exactly that shape by a JSON Schema it turns into a grammar. An
-- action outside the union, a field it does not have, or a missing field
-- cannot be sampled. The program decides what each action does; see
-- llmq-agent.
--
-- This is the approach of Grace's tools example (a union decoded under a
-- grammar and folded into effects) rather than OpenAI-style function
-- calling, which depends on a model having been trained on a tool-call
-- format and which small open models do unreliably. Choosing among a few
-- alternatives and filling in their fields is something a 7B model does
-- well when the grammar rules out everything else.
--
-- ============================================================================
-- THE SAME TYPE IN GRACE
-- ============================================================================
--
-- 'decisionSchema' is the schema Grace's `prompt` derives from the Grace
-- type in stages/agent-step.ffg, rule for rule: a union is an object whose
-- anyOf alternatives carry a constant "tag" and a "contents", a record
-- lists every field as required and allows no others, an Optional is anyOf
-- the type and null, and Natural is a JSON number. So a Grace stage and
-- llmq-agent ask a model the same question, and llmq-grace checks the
-- stage's type against these Haskell types when it loads it.
--
-- Labels avoid the words Grace's lexer treats as import schemes (`file`,
-- `http`, `https`, `env`), which start an import wherever they appear.
-- Alternatives avoid starting with a built-in type's name: Grace's lexer
-- tries `List`, `Text`, `Optional` and the rest before an alternative, with
-- no word boundary, so an alternative called ListFiles lexes as List then
-- Files and the stage does not parse (found 2026-10-16 loading
-- stages/agent-step.ffg). Hence BrowseDirectory.
--
-- ============================================================================
-- FIELD ORDER
-- ============================================================================
--
-- The grammar fixes the order the model writes fields in, and that order is
-- the order of the schema's text, which aeson writes alphabetically (Grace's
-- schemas too). Measured 2026-10-16 with llama.cpp's own converter, the one
-- llama-server and ollama use: the grammar for this schema demands "plan"
-- before "step", and inside a union alternative "contents" before "tag".
-- So the labels are chosen to sort into the order a person would write
-- them: plan before step, path before what is done to it, the text to
-- replace before its replacement (path, replace, with), and a read's start
-- before its stop.
module OpenSlop.Agent.Action
  ( Decision (..)
  , Action (..)
  , BrowseDirectoryArgs (..)
  , ReadFileArgs (..)
  , SearchIndexArgs (..)
  , LookupSourceArgs (..)
  , ReplaceTextArgs (..)
  , WriteFileArgs (..)
  , FinishArgs (..)
  , Kind (..)
  , allKinds
  , kindOf
  , kindName
  , isEdit
  , decisionSchema
  , describeActions
  , instructions
  , decodeDecision
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value (..)
  , eitherDecodeStrict
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | One turn of the model's: what it intends, then what it does.
data Decision = Decision
  { plan :: Text
  , step :: Action
  }
  deriving stock (Eq, Show, Generic)

data Action
  = BrowseDirectory BrowseDirectoryArgs
  | ReadFile ReadFileArgs
  | SearchIndex SearchIndexArgs
  | LookupSource LookupSourceArgs
  | ReplaceText ReplaceTextArgs
  | WriteFile WriteFileArgs
  | Check
  | Finish FinishArgs
  deriving stock (Eq, Show, Generic)

-- | A directory relative to the project root; "" or "." is the root.
newtype BrowseDirectoryArgs = BrowseDirectoryArgs {directory :: Text}
  deriving stock (Eq, Show, Generic)

-- | Lines are 1-based and inclusive. Either bound may be left out.
data ReadFileArgs = ReadFileArgs
  { path :: Text
  , startLine :: Maybe Natural
  , stopLine :: Maybe Natural
  }
  deriving stock (Eq, Show, Generic)

newtype SearchIndexArgs = SearchIndexArgs {query :: Text}
  deriving stock (Eq, Show, Generic)

-- | "Module" or "Module#name", as tricorder source takes it.
newtype LookupSourceArgs = LookupSourceArgs {query :: Text}
  deriving stock (Eq, Show, Generic)

-- | Replace the one occurrence of `replace` with `with`.
data ReplaceTextArgs = ReplaceTextArgs
  { path :: Text
  , replace :: Text
  , with :: Text
  }
  deriving stock (Eq, Show, Generic)

-- | Create a file or replace all of it.
data WriteFileArgs = WriteFileArgs
  { path :: Text
  , text :: Text
  }
  deriving stock (Eq, Show, Generic)

newtype FinishArgs = FinishArgs {summary :: Text}
  deriving stock (Eq, Show, Generic)

-- | The alternatives without their fields, for choosing which ones a run
-- offers.
data Kind
  = KBrowseDirectory
  | KReadFile
  | KSearchIndex
  | KLookupSource
  | KReplaceText
  | KWriteFile
  | KCheck
  | KFinish
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allKinds :: [Kind]
allKinds = [minBound .. maxBound]

kindOf :: Action -> Kind
kindOf = \case
  BrowseDirectory _ -> KBrowseDirectory
  ReadFile _ -> KReadFile
  SearchIndex _ -> KSearchIndex
  LookupSource _ -> KLookupSource
  ReplaceText _ -> KReplaceText
  WriteFile _ -> KWriteFile
  Check -> KCheck
  Finish _ -> KFinish

-- | The tag, as Grace and the schema spell it.
kindName :: Kind -> Text
kindName = \case
  KBrowseDirectory -> "BrowseDirectory"
  KReadFile -> "ReadFile"
  KSearchIndex -> "SearchIndex"
  KLookupSource -> "LookupSource"
  KReplaceText -> "ReplaceText"
  KWriteFile -> "WriteFile"
  KCheck -> "Check"
  KFinish -> "Finish"

isEdit :: Action -> Bool
isEdit = \case
  ReplaceText _ -> True
  WriteFile _ -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- JSON, in Grace's encoding

instance ToJSON Decision where
  toJSON d = object ["plan" .= d.plan, "step" .= d.step]

instance FromJSON Decision where
  parseJSON = withObject "decision" \o -> Decision <$> o .: "plan" <*> o .: "step"

instance ToJSON Action where
  toJSON a = object ["tag" .= kindName (kindOf a), "contents" .= contents]
    where
      contents = case a of
        BrowseDirectory x -> object ["directory" .= x.directory]
        ReadFile x -> object ["path" .= x.path, "startLine" .= x.startLine, "stopLine" .= x.stopLine]
        SearchIndex x -> object ["query" .= x.query]
        LookupSource x -> object ["query" .= x.query]
        ReplaceText x -> object ["path" .= x.path, "replace" .= x.replace, "with" .= x.with]
        WriteFile x -> object ["path" .= x.path, "text" .= x.text]
        Check -> object []
        Finish x -> object ["summary" .= x.summary]

instance FromJSON Action where
  parseJSON = withObject "action" \o -> do
    tag <- o .: "tag"
    c <- o .: "contents"
    flip (withObject "contents") c \f -> case tag :: Text of
      "BrowseDirectory" -> BrowseDirectory . BrowseDirectoryArgs <$> f .: "directory"
      "ReadFile" -> ReadFile <$> (ReadFileArgs <$> f .: "path" <*> natural f "startLine" <*> natural f "stopLine")
      "SearchIndex" -> SearchIndex . SearchIndexArgs <$> f .: "query"
      "LookupSource" -> LookupSource . LookupSourceArgs <$> f .: "query"
      "ReplaceText" -> ReplaceText <$> (ReplaceTextArgs <$> f .: "path" <*> f .: "replace" <*> f .: "with")
      "WriteFile" -> WriteFile <$> (WriteFileArgs <$> f .: "path" <*> f .: "text")
      "Check" -> pure Check
      "Finish" -> Finish . FinishArgs <$> f .: "summary"
      other -> fail ("no action is called " <> T.unpack other)
    where
      -- Grace's Natural is a JSON number, so 12.0 is 12; a fraction or a
      -- negative is refused.
      natural f k = do
        v <- f .: k
        case v of
          Null -> pure Nothing
          Number n -> case floatingOrInteger n :: Either Double Integer of
            Right i | i >= 0 -> pure (Just (fromIntegral i))
            _ -> fail (T.unpack (Key.toText k) <> " must be a whole number of at least 0")
          _ -> fail (T.unpack (Key.toText k) <> " must be a number or null")

-- | A model's answer, read as a decision. The servers constrain decoding to
-- the schema, so a failure here means the answer was cut off or the server
-- ignored the schema.
decodeDecision :: Text -> Either Text Decision
decodeDecision raw = either (Left . T.pack) Right (eitherDecodeStrict (TE.encodeUtf8 (stripFence raw)))
  where
    -- A server that ignored the schema sometimes wraps the JSON in a code
    -- fence; nothing else is tolerated.
    stripFence t =
      let s = T.strip t
       in case T.stripPrefix "```" s of
            Just rest -> T.strip (T.dropWhileEnd (== '`') (T.dropWhile (/= '\n') rest))
            Nothing -> s

-- ---------------------------------------------------------------------------
-- the schema

-- | The schema of a 'Decision' whose step is one of the given kinds. A run
-- offers only what it can carry out: no SearchIndex without an index, no
-- edits in a read-only run.
decisionSchema :: [Kind] -> Value
decisionSchema kinds =
  record [("plan", textT), ("step", union [(kindName k, fieldsOf k) | k <- allKinds, k `elem` kinds])]
  where
    fieldsOf = \case
      KBrowseDirectory -> record [("directory", textT)]
      KReadFile -> record [("path", textT), ("startLine", optional naturalT), ("stopLine", optional naturalT)]
      KSearchIndex -> record [("query", textT)]
      KLookupSource -> record [("query", textT)]
      KReplaceText -> record [("path", textT), ("replace", textT), ("with", textT)]
      KWriteFile -> record [("path", textT), ("text", textT)]
      KCheck -> record []
      KFinish -> record [("summary", textT)]

record :: [(Text, Value)] -> Value
record fields =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object [(Key.fromText k, v) | (k, v) <- fields]
    , "additionalProperties" .= False
    , "required" .= map fst fields
    ]

union :: [(Text, Value)] -> Value
union alternatives =
  object
    [ "type" .= ("object" :: Text)
    , "anyOf"
        .= [ object
               [ "type" .= ("object" :: Text)
               , "properties"
                   .= object
                     [ "tag" .= object ["type" .= ("string" :: Text), "const" .= tag]
                     , "contents" .= contents
                     ]
               , "required" .= (["tag", "contents"] :: [Text])
               , "additionalProperties" .= False
               ]
           | (tag, contents) <- alternatives
           ]
    ]

optional :: Value -> Value
optional t = object ["anyOf" .= [t, object ["type" .= ("null" :: Text)]]]

textT :: Value
textT = object ["type" .= ("string" :: Text)]

naturalT :: Value
naturalT = object ["type" .= ("number" :: Text)]

-- ---------------------------------------------------------------------------
-- the instructions

-- | One paragraph per offered action, for the system message. The schema
-- says what may be written; this says when each is useful.
describeActions :: [Kind] -> Text
describeActions kinds = T.unlines [describe k | k <- allKinds, k `elem` kinds]
  where
    describe = \case
      KBrowseDirectory -> "BrowseDirectory {directory}: the files and directories directly under a directory of the project, relative to its root. Use \"\" for the root."
      KReadFile -> "ReadFile {path, startLine, stopLine}: a file's lines, numbered. Leave both lines null for the whole file, or give a range when the file is long."
      KSearchIndex -> "SearchIndex {query}: search the user's indexed files and notes by meaning and by words. Use it to find where something is defined or discussed."
      KLookupSource -> "LookupSource {query}: the source of a module, \"Data.Map.Strict\", or of one definition in it, \"Data.Map.Strict#insertWith\", from the project or any installed library, as the compiler sees it. Use it instead of guessing a library's API."
      KReplaceText -> "ReplaceText {path, replace, with}: replace text in a file. replace must be copied exactly from the file, including indentation, and must occur in it exactly once; include enough surrounding lines to make it unique. with is the new text. The build is checked after every edit."
      KWriteFile -> "WriteFile {path, text}: create a file, or replace all of it. Prefer ReplaceText for a change to part of an existing file. The build is checked after every edit."
      KCheck -> "Check {}: the latest build's errors and warnings and the test results."
      KFinish -> "Finish {summary}: stop, with a summary of what was done or the answer to the question. After edits, Finish is accepted only when the build has no errors and the tests pass."

-- | The system message for a run offering these actions. llmq-agent and
-- the Grace stage stages/agent-step.ffg (through llmq-grace) both send it.
instructions :: [Kind] -> Text
instructions kinds =
  T.unlines
    [ "You are a careful software engineer working in a project directory on the user's machine."
    , "You act one step at a time. Every reply is one decision in JSON: plan, then step."
    , "plan is one or two sentences: what the last result told you, and what you will do next and why."
    , "step is exactly one of these actions:"
    , ""
    , describeActions kinds
    , "Paths are relative to the project root."
    , "Work from what the files and the compiler say, not from memory. Read a file before you edit it."
    , "When the build has errors, fix the first one first; later errors are often caused by it."
    , "Keep changes as small as the task allows, and do not change what the task did not ask for."
    ]
