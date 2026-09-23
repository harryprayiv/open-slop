Q: Now that we’re using Grace.  Is it capable of calling itself,  Grace code is, after all, designed to query multiple parts using AI while keeping the rest of the code deterministic.  Show me how it would hypothetically work in the case of the chase annotation script I want to use on my Haskell projects.

A

Short answer: Grace cannot recurse, and that is the property that makes it safe to put between a model and your code. It can call the model many times in one program, it can chain one call's typed output into the next, and through `import prompt` it can have the model write Grace that Grace then type-checks and runs. The loop that decides "try again until the checker is satisfied" cannot be written in Grace; it lives in Haskell, where chase already has it.

## What Grace can and cannot do, from its source

- **No general recursion.** `let` is not recursive and there is no fixpoint. The only iteration is `map` and `fold`, and `fold` is structural: `true/false` on Bool, `zero/succ` on Natural, `some/null` on Optional, `cons/nil` on List, one handler per alternative on a union. Every Grace program terminates apart from the time its prompts take. A program the model writes cannot loop either.
- **Many prompts per program, run in order.** `map (\s -> prompt{ ... } : T) xs` makes one call per element. The normaliser has no concurrency, so they run one after another, which is also how oracle serves them.
- **Chaining with inferred types.** One prompt's typed result is an ordinary value for the next prompt's text. Grace infers each intermediate schema from how the value is used.
- **`import prompt : T`.** The model writes Grace code of type `T`; Grace type-checks it before running it; that code may itself use `prompt`. This is the sense in which Grace calls itself. The cost is the 29 KB grammar and language guide Grace puts in front of the model so it can write Grace, about 8,000 tokens, which on oracle is 25 minutes of prefill per generation before the model reads your question. Not on this hardware.
- **No calls into Haskell.** A Grace program cannot run chase's drift checker. The check has to happen outside the program, on the typed value it returns.

That settles the division of labour for chase: **Grace is one typed step; Haskell is the loop, the checks, and the persistence.**

## chase-annotate on a small model, hypothetically

Today's `genAnnotations.ffg` makes one call per module that asks for invariants on every signature, decisions, and open issues together. Everything measured this week says a 7B will not do that well: given four files in one part it documented one and stopped, and at 8K of context it decodes at 0.7 tok/s. The same fix that worked for llmq applies here: small, single-subject prompts, orchestrated deterministically.

Three stages:

1. **Per signature (Grace, one call each).** Input: the module bundle and one parsed signature. Output type `{ body: List Text, consumes: List Text }`. The function name is *not* in the output type. Haskell attaches it from the parser, so an invariant naming a function chase never saw is unrepresentable rather than something the drift checker has to catch.
2. **Render (Haskell, deterministic).** Merge the stage-1 invariants into the parsed file and render it with chase's own renderer. The model's context for stage 3 is chase's output format, invariants included, with no second serialisation of the same data.
3. **Per module (Grace, one call, retried).** Input: the annotated bundle and any drift warnings. Output `{ decisions, openIssues }`. Only this stage is re-asked by the drift loop, because only its `affects` fields name things freely.

The result is the same `GenAnnotations` the bridge already converts, so `toModuleAnnotations`, the drift checker and the writer do not change.

### The prefix-cache bet

Stage 1 is where this design earns or loses its keep on oracle. Every stage-1 call for a module is: fixed instructions, then the bundle, then one signature. Everything before the signature is identical across the module's calls, and a server that keeps its KV cache between requests (ollama with one slot; llama-server, which the gateway sends `cache_prompt` through) only prefills the part that changed. From this week's rate curve, for a module of 20 signatures with a 1,500-token bundle:

| | per signature | 20 signatures |
|---|---|---|
| no cache reuse | about 195 s prefill at ~9 tok/s, 57 s for 80 output tokens at ~1.4 | about 84 min |
| prefix reused after the first call | about 5 s prefill, 57 s output | about 23 min |

Stage 3 at about 2,500 tokens is roughly 5 minutes of prefill and 5 of output per attempt. So a module is somewhere between 35 and 95 minutes on `qwen2.5-coder:7b`, and which end depends entirely on whether the prefix is reused. That is unmeasured; the gateway's log line for the second stage-1 call answers it, because ollama reports only the prompt tokens it actually evaluated.

### `grace/annotateSignature.ffg`

```
# One signature's annotation, for a small local model.
#
# Called from Haskell once per signature chase parsed, as a typed function
# SignatureArgs -> IO SignatureAnnotation. The function's name is not in
# the result type; the caller attaches it from the parser, so the model
# cannot attach an invariant to a function that does not exist.
#
# The text is fixed instructions, then the module bundle, then the one
# signature. Every call for the same module shares everything before the
# signature, so a server that keeps its KV cache between requests prefills
# only the tail after the first call.
#
# Not yet run.

\arguments ->

let key = arguments.key
let model = arguments.model
let signature = arguments.signature

in  prompt
      { key
      , model
      , text: "
          You annotate one function of a Haskell or PureScript module for a
          maintainer who knows the language well.

          Rules:
          - State only what the bundle shows or what the signature and name
            make certain. Leave out anything the bundle does not show.
          - Each statement is one short sentence about behaviour, effects,
            or an invariant the function keeps.
          - At most four statements. Zero statements is an acceptable answer.
          - In consumes, list only names that appear in the bundle and that
            this function uses.

          Module ${arguments.modName}, chase bundle (bodies omitted):

          ${arguments.bundle}

          Function to annotate:

          ${signature.name} :: ${signature.typeText}
          "
      }
      : { body: List Text, consumes: List Text }
```

### `grace/annotateModule.ffg`

```
# Decisions and open issues for one module, given its bundle with the
# per-signature invariants already rendered into it by chase.
#
# Called from Haskell as ModuleArgs -> IO ModuleLevel, and re-called with
# the drift checker's warnings when an `affects` or `blocking` entry names
# something the parser did not see.
#
# Not yet run.

\arguments ->

let key = arguments.key
let model = arguments.model
let driftWarnings = arguments.driftWarnings

let driftSection =
      if length driftWarnings == 0
      then ""
      else "
        The previous attempt produced these drift warnings:

        ${fold { cons: \x y -> "- ${x}\n${y}", nil: "" } driftWarnings}

        Every name in affects and blocking must appear verbatim in the bundle.
        "

in  prompt
      { key
      , model
      , text: "
          You record the design of the Haskell or PureScript module
          ${arguments.modName} for a maintainer who knows the language well.

          The bundle below is chase's structural skeleton. Lines beginning
          with ! under a signature are invariants already written for that
          function; do not repeat them.

          ${arguments.annotatedBundle}

          Decisions: only non-obvious design choices visible in the module's
          shape. affects lists signature names from the bundle, verbatim.

          Open issues: only clear hazards visible in the code shape, such as
          partial functions, unsafe assumptions, or obvious gaps. Zero is an
          acceptable answer.

          Prefer fewer high-confidence entries to many low-confidence ones.

          ${driftSection}
          "
      }
      : { decisions:
            List { name: Text, what: Text, why: Text, affects: List Text }
        , openIssues:
            List { name: Text, what: Text, why: Text, blocking: List Text, affects: List Text }
        }
```

### `src-bridge/Chase/GraceStaged.hs`

The orchestration, against the bridge on your `chaseGrace` branch. It needs one change there: `mergeForCheck` added to `Chase.GraceBridge`'s export list. Two things it does not know about chase are taken as arguments rather than guessed: how to list a module's signatures, and how to render a `ChaseFile` as a bundle. Not compiled; the sandbox has no Grace.

```haskell
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}

-- | Annotation generation in stages, for small local models.
--
-- Grace does one typed step at a time; this module does everything a
-- Grace program cannot: the iteration over signatures, the drift check,
-- the retry, and the rendering in between, all deterministic.
--
--   1. one call per signature: body and consumes only; the name comes
--      from the parser, so it cannot drift
--   2. render: stage-1 invariants merged into the file and rendered by
--      chase, which becomes stage 3's context
--   3. one call per module: decisions and open issues, retried against
--      the drift checker up to the budget
--
-- The result is the bridge's GenAnnotations, so everything downstream of
-- generateWithDriftFeedback works unchanged on it.
module Chase.GraceStaged
  ( SignatureRef (..)
  , SignatureArgs (..)
  , SignatureAnnotation (..)
  , ModuleArgs (..)
  , ModuleLevel (..)
  , Stages (..)
  , loadStages
  , annotateStaged
  ) where

import Control.Monad.IO.Class (MonadIO)
import Data.Text              (Text)
import GHC.Generics           (Generic)
import Grace.Decode           (FromGrace, Key (..), ToGraceType)
import Grace.Encode           (ToGrace)
import Grace.Input            (Input (..), Mode (..))
import Grace.Interpret        (load)

import Chase.GraceBridge
  ( GenAnnotations (..)
  , GenDecision
  , GenInvariant (..)
  , GenOpenIssue
  , mergeForCheck
  , toModuleAnnotations
  )

import qualified Chase.Pipeline as Pipeline
import qualified Chase.Types    as CT

-- | A signature as the parser saw it.
data SignatureRef = SignatureRef
  { name     :: Text
  , typeText :: Text
  } deriving stock    (Generic, Show)
    deriving anyclass (ToGrace, ToGraceType)

data SignatureArgs = SignatureArgs
  { key       :: Key
  , model     :: Text
  , modName   :: Text
  , bundle    :: Text
  , signature :: SignatureRef
  } deriving stock    (Generic, Show)
    deriving anyclass (ToGrace, ToGraceType)

-- | What the model writes for one signature. No name field, on purpose.
data SignatureAnnotation = SignatureAnnotation
  { body     :: [Text]
  , consumes :: [Text]
  } deriving stock    (Generic, Show)
    deriving anyclass (FromGrace, ToGraceType)

data ModuleArgs = ModuleArgs
  { key             :: Key
  , model           :: Text
  , modName         :: Text
  , annotatedBundle :: Text
  , driftWarnings   :: [Text]
  } deriving stock    (Generic, Show)
    deriving anyclass (ToGrace, ToGraceType)

data ModuleLevel = ModuleLevel
  { decisions  :: [GenDecision]
  , openIssues :: [GenOpenIssue]
  } deriving stock    (Generic, Show)
    deriving anyclass (FromGrace, ToGraceType)

-- | The two Grace files, decoded as typed Haskell functions.
data Stages = Stages
  { perSignature :: SignatureArgs -> IO SignatureAnnotation
  , perModule    :: ModuleArgs -> IO ModuleLevel
  }

loadStages :: MonadIO m => FilePath -> FilePath -> m Stages
loadStages signaturePath modulePath =
  Stages
    <$> load (Path signaturePath AsCode)
    <*> load (Path modulePath AsCode)

-- | Run the three stages for one module. Returns the annotations and the
-- drift warnings left after the retry budget, the same pair as
-- generateWithDriftFeedback.
--
-- Only stage 3 is retried. A drifting `consumes` entry from stage 1
-- survives to the returned warnings, the same way a non-converging module
-- does today, and is left to the reviewer.
annotateStaged
  :: Stages
  -> Int                      -- ^ retries for stage 3
  -> Key                      -- ^ gateway key
  -> Text                     -- ^ model id, e.g. oracle/cpu/qwen2.5-coder:7b
  -> (CT.ChaseFile -> Text)   -- ^ chase's renderer for one module's bundle
  -> [SignatureRef]           -- ^ the module's signatures, from the parser
  -> CT.ChaseFile
  -> IO (GenAnnotations, [Text])
annotateStaged Stages{..} maxRetries k model render signatures chaseFile = do
  let modName = CT.chaseModuleName chaseFile
      bundle  = render chaseFile

  written <- traverse
    (\s -> perSignature SignatureArgs{ key = k, model, modName, bundle, signature = s })
    signatures

  let invariants =
        [ GenInvariant{ function = s.name, body = a.body, consumes = a.consumes }
        | (s, a) <- zip signatures written
        , not (null a.body)
        ]
      stageOne        = GenAnnotations{ invariants, decisions = [], openIssues = [] }
      annotatedBundle = render (mergeForCheck chaseFile (toModuleAnnotations modName stageOne))

      loop attempt warnings = do
        level <- perModule ModuleArgs{ key = k, model, modName, annotatedBundle, driftWarnings = warnings }
        let result = GenAnnotations{ invariants, decisions = level.decisions, openIssues = level.openIssues }
            fresh  = Pipeline.checkAnnotationDrift
                       (mergeForCheck chaseFile (toModuleAnnotations modName result))
        if null fresh || attempt >= maxRetries
          then pure (result, fresh)
          else loop (attempt + 1) fresh

  loop (0 :: Int) []
```

## Why stage 1 is called from Haskell rather than with Grace's `map`

Grace's `map` would do the same fan-out inside one `.ffg`, and for a demo that is the shorter program. It is the wrong shape for oracle: a project of 30 modules at 35 to 95 minutes each is a day or two of work, and one Grace call that fans out internally is all-or-nothing. A process killed halfway loses every finished signature. With Haskell doing the iteration, each signature's typed result is a value the caller can persist before asking for the next, which is exactly llmq's part model. That is where `llmq-grace` comes in later: the same two `.ffg` files, with llmq's job directory holding one JSON result per signature, resumable and lock-protected, the drift loop running at the module boundary.

## What this does not fix

- **The `why` of a decision.** A 7B can write a plausible design rationale for a choice the module never made. The schema guarantees shape, the parser guarantees names, and nothing guarantees the claim. Your reading is still the check, the same as today.
- **`import prompt` on oracle.** The grammar preamble makes it a 25-minute prefill per generation. Testing whether a small model can write Grace is a separate experiment, against a hosted model or with a much shorter grammar prompt of your own, and it is not on the path of this design.

## What it takes to try

The single-call `record.ffg` passing against the gateway comes first; it proves the bindings decode the gateway's responses, and nothing here works without that. After it, on winsmuth against the local ollama from earlier, with `qwen2.5:0.5b` in place of the 7B:

1. the one-word export change in `Chase.GraceBridge`, the two `.ffg` files, `GraceStaged.hs`, and `chase-annotate` calling `annotateStaged` behind a flag;
2. one small module through it, with the gateway's log open to read the prompt-token count of the second stage-1 call. That number decides the design: small means the prefix was reused and the per-module cost is near 23 minutes on oracle; the full bundle count means it was not, and the stage-1 prompt needs to be built around the cache instead.