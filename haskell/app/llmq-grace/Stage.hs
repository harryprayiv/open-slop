-- | Loading a Grace stage as a Haskell function.
--
-- A stage is a Grace file whose value is a function from 'PartArgs' to the
-- stage's result type. `Grace.Interpret.load` annotates the file with the
-- Haskell type before inferring it, so a file whose own type does not match
-- fails at load, before a single request is sent. That is the guarantee
-- this executable exists for: the pipeline's shape is checked when it
-- starts, not discovered from a model's prose at the end.
--
-- The instances for the result types are orphans on purpose. The types live
-- in the library, which has no Grace dependency, so that the rendering and
-- the coverage check compile and test without building Grace.
{-# OPTIONS_GHC -Wno-orphans #-}

module Stage
  ( PartArgs (..)
  , loadDocsStage
  , AgentArgs (..)
  , loadAgentStage
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Grace.Decode (FromGrace, Key (..), ToGraceType)
import Grace.Encode (ToGrace)
import Grace.Input (Input (..), Mode (..))
import Grace.Interpret (load)
import OpenSlop.Agent.Action
import OpenSlop.Grace.Docs (Docs, FileDoc)

-- | What every stage is given for one part. The key and the model are
-- passed in rather than read by the Grace file, so one stage file works
-- against any gateway and no key is written in a program.
--
-- The model is Maybe Text because Grace's own prompt record types its
-- model field as Optional Text, and a stage passing args.model straight
-- through fails to type-check against a plain Text.
data PartArgs = PartArgs
  { key :: Key
  , model :: Maybe Text
  , path :: Text
  -- ^ the file this part covers, or the first of them
  , source :: Text
  , part :: Int
  , parts :: Int
  }
  deriving stock (Generic)
  deriving anyclass (ToGrace, ToGraceType)

instance ToGraceType FileDoc

instance FromGrace FileDoc

instance ToGraceType Docs

instance FromGrace Docs

-- | Load a reference-docs stage. The signature is the contract: `load`
-- infers the file against this type, and a stage file that disagrees with
-- it does not load. No type application, because `load`'s first type
-- variable is the monad, not the result.
loadDocsStage :: FilePath -> IO (PartArgs -> IO Docs)
loadDocsStage file = load (Path file AsCode)

-- | What an agent step is given: the instructions and the conversation so
-- far, already rendered, so the Grace file only declares the type.
data AgentArgs = AgentArgs
  { key :: Key
  , model :: Maybe Text
  , instructions :: Text
  , conversation :: Text
  }
  deriving stock (Generic)
  deriving anyclass (ToGrace, ToGraceType)

instance ToGraceType BrowseDirectoryArgs

instance FromGrace BrowseDirectoryArgs

instance ToGraceType ReadFileArgs

instance FromGrace ReadFileArgs

instance ToGraceType SearchIndexArgs

instance FromGrace SearchIndexArgs

instance ToGraceType LookupSourceArgs

instance FromGrace LookupSourceArgs

instance ToGraceType ReplaceTextArgs

instance FromGrace ReplaceTextArgs

instance ToGraceType WriteFileArgs

instance FromGrace WriteFileArgs

instance ToGraceType FinishArgs

instance FromGrace FinishArgs

instance ToGraceType Action

instance FromGrace Action

instance ToGraceType Decision

instance FromGrace Decision

-- | Load an agent step. The Haskell 'Decision' is the contract, the same
-- way 'Docs' is for the reference-docs stage: a .ffg whose union has a
-- different alternative, a field of another name or type, or a missing
-- field does not load.
loadAgentStage :: FilePath -> IO (AgentArgs -> IO Decision)
loadAgentStage file = load (Path file AsCode)