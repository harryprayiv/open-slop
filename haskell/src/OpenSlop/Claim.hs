-- | Claims: what a model is allowed to say about source text, and the
-- checks that decide whether it said it.
--
-- ============================================================================
-- THE MODEL POINTS, IT DOES NOT COMPOSE
-- ============================================================================
--
-- A claim names a subject drawn from a list the caller supplies, quotes the
-- source verbatim as its evidence, and adds one sentence. Everything else
-- is closed: the kind is an enum and the subject is an enum, so under the
-- grammar the server decodes with, a file or a category that does not exist
-- is not a reachable token.
--
-- Evidence is quoted text rather than byte offsets. A model cannot count
-- bytes, and asking it to invites a plausible number pointing at the wrong
-- line. A quote either occurs in the source or it does not, which is a
-- substring search, and the offsets are recovered here.
--
-- ============================================================================
-- WHAT EACH CHECK CATCHES
-- ============================================================================
--
--   subjectKnown      a claim about something not in this part
--   statementComplete a sentence the grammar's length bound cut off
--   evidenceResolves  a quote that is not in the source: an invented fact
--   evidenceIsApt     a quote sharing no name with its statement, which is
--                     how a colon-ended lead-in gets cited for the lines
--                     below it
--   identifiersKnown  a statement naming something that appears nowhere in
--                     the source: the most damaging failure, a set lookup
--   reasonIsStated    a rationale the model supplied rather than found
--   notDuplicate      the same claim twice, which small models do under a
--                     schema asking for a list
--
-- Nothing here judges whether a claim is TRUE. These checks remove claims
-- that cannot be true, and one measured failure shows the limit: a claim
-- quoting a fail-message helper, "homebeacon-keycheck: $1", and reading $1
-- as the script's first argument. Real quote, wrong reading, every check
-- passed. That is the job of an entailment model, not of a substring test.
module OpenSlop.Claim
  ( ClaimKind (..)
  , Confidence (..)
  , RawClaim (..)
  , Claim (..)
  , Evidence (..)
  , CheckName
  , Verdict (..)
  , Subject (..)
  , claimSchema
  , verify
  , renderClaims
  , identifiersIn
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withText, (.=))
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace, isUpper)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | What a claim is about: a file, a declaration, whatever the caller's
-- parser knows. The caller supplies the list; the schema turns it into an
-- enum; the model can only choose.
data Subject = Subject
  { name :: Text
  , source :: Text
  -- ^ the text the claim's evidence must be found in
  }
  deriving stock (Show, Eq)

data ClaimKind = Purpose | Interface | Behaviour | Reason | OpenIssue
  deriving stock (Show, Eq, Ord, Enum, Bounded)

kindText :: ClaimKind -> Text
kindText = \case
  Purpose -> "purpose"
  Interface -> "interface"
  Behaviour -> "behaviour"
  Reason -> "reason"
  OpenIssue -> "openIssue"

instance ToJSON ClaimKind where
  toJSON = toJSON . kindText

instance FromJSON ClaimKind where
  parseJSON = withText "kind" \t ->
    case [k | k <- [minBound .. maxBound], kindText k == t] of
      (k : _) -> pure k
      [] -> fail ("unknown claim kind " <> T.unpack t)

-- | DERIVED, never asked for. See the note on the schema below.
data Confidence = Stated | Inferred
  deriving stock (Show, Eq, Ord, Enum, Bounded)

confidenceText :: Confidence -> Text
confidenceText = \case
  Stated -> "stated"
  Inferred -> "inferred"

instance ToJSON Confidence where
  toJSON = toJSON . confidenceText

instance FromJSON Confidence where
  parseJSON = withText "confidence" \t ->
    case [c | c <- [minBound .. maxBound], confidenceText c == t] of
      (c : _) -> pure c
      [] -> fail ("unknown confidence " <> T.unpack t)

-- | Exactly what the model returns. Every field is either closed or
-- checkable, and there is no field whose value is the model's opinion of
-- its own work.
data RawClaim = RawClaim
  { subject :: Text
  , kind :: ClaimKind
  , quotes :: [Text]
  , statement :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A quote, located. The offsets are into the subject's source with
-- whitespace normalised, so they are a pointer for a reader rather than a
-- byte range for a machine.
data Evidence = Evidence
  { quote :: Text
  , start :: Int
  , end :: Int
  , inComment :: Bool
  -- ^ the quote came from a comment, which is what makes a claim stated
  -- rather than inferred
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Claim = Claim
  { subject :: Text
  , kind :: ClaimKind
  , evidence :: [Evidence]
  , statement :: Text
  , confidence :: Confidence
  , passed :: [CheckName]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

type CheckName = Text

-- | Accepted claims, and the ones that failed with the reason. Nothing is
-- silently dropped: a rejected claim is kept for reading, because a model
-- that keeps failing one check is telling you something about the prompt.
data Verdict = Verdict
  { accepted :: [Claim]
  , rejected :: [(RawClaim, Text)]
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON)

-- ---------------------------------------------------------------------------
-- The schema

-- | The JSON Schema for a list of claims about one subject list.
--
-- minItems and maxItems make coverage a property of the grammar rather
-- than a warning afterwards: measured 2026-09-26, the same model that
-- documented one file of two without them documented both with them.
--
-- maxLength on the statement, after a run in which the instruction said
-- "at most thirty words" and the model wrote sixty and kept going to the
-- token cap, four subjects in a row, producing no valid JSON at all. A
-- rule a model can ignore is not a constraint. The bound does not steer
-- the model, it cuts it off, which is why a truncated sentence is rejected
-- below.
--
-- The bounds cost nothing: measured warm, the same request with no bound,
-- a 60-character bound and a 220-character bound all took 25 seconds and
-- returned the same answer.
--
-- There is no confidence field. It used to be the model's to choose, and
-- requiring kind=reason to carry confidence=stated taught the model to
-- avoid both labels: every claim in that run came back inferred, several
-- quoting comments that state the fact outright, and not one was labelled
-- a reason. Confidence is derived from where the quote landed.
claimSchema :: [Text] -> (Int, Int) -> Value
claimSchema subjects (lo, hi) =
  object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= object
          [ "claims"
              .= object
                [ "type" .= ("array" :: Text)
                , "minItems" .= lo
                , "maxItems" .= hi
                , "items"
                    .= object
                      [ "type" .= ("object" :: Text)
                      , "properties"
                          .= object
                            [ "subject" .= object ["type" .= ("string" :: Text), "enum" .= subjects]
                            , "kind" .= object ["type" .= ("string" :: Text), "enum" .= map kindText [minBound .. maxBound]]
                            , "quotes"
                                .= object
                                  [ "type" .= ("array" :: Text)
                                  , "minItems" .= (1 :: Int)
                                  , "maxItems" .= (2 :: Int)
                                  , -- minLength, so a quote too short to identify
                                    -- anything is not a reachable token under the
                                    -- grammar rather than something the checker
                                    -- removes after the tokens are paid for.
                                    -- maxLength for the same reason in the other
                                    -- direction: a quote is fifteen words, not a
                                    -- transcription of the file.
                                    "items"
                                      .= object
                                        [ "type" .= ("string" :: Text)
                                        , "minLength" .= (12 :: Int)
                                        , "maxLength" .= (120 :: Int)
                                        ]
                                  ]
                            , "statement" .= object ["type" .= ("string" :: Text), "minLength" .= (20 :: Int), "maxLength" .= (220 :: Int)]
                            ]
                      , "required" .= (["subject", "kind", "quotes", "statement"] :: [Text])
                      , "additionalProperties" .= False
                      ]
                ]
          ]
    , "required" .= (["claims"] :: [Text])
    , "additionalProperties" .= False
    ]

-- ---------------------------------------------------------------------------
-- The checks

-- | Tokens that look like code rather than English, so a statement can be
-- checked against the source without every ordinary word being flagged.
--
-- A token counts when it carries a separator (dot, slash, dash,
-- underscore, colon, at-sign), has an inner capital, is all capitals, or
-- mixes letters with digits. An English word in lower case never does.
-- Trailing punctuation is stripped, since a model writes "foo.bar." at the
-- end of a sentence.
identifiersIn :: Text -> Set Text
identifiersIn t =
  Set.fromList
    [ w
    | raw <- T.split (\c -> c == ' ' || c == '\n' || c == '\t' || c == ',' || c == '(' || c == ')' || c == '"' || c == '`' || c == '\'') t
    , let w = T.dropAround (`elem` (".,;:!?" :: String)) raw
    , T.length w >= 2
    , codeLike w
    ]
  where
    codeLike w
      -- Two characters is enough when one is a digit and one a letter (v2,
      -- x1), and never otherwise, so "is", "of" and "it" stay out.
      | T.length w == 2 = T.any isDigit w && T.any isAlpha w
    codeLike w =
      T.any (`elem` ("._-/:@" :: String)) (T.drop 1 (T.init w))
        || T.any isUpper (T.drop 1 w)
        || (T.all (\c -> isUpper c || not (isAlpha c)) w && T.any isAlpha w)
        -- A letter next to a digit: v2, sha256, ed25519. Without this the
        -- aptness check below had nothing to work with on a statement whose
        -- only specific word was "v2", and passed a claim citing the line
        -- that announces a message format instead of the format itself.
        || (T.any isDigit w && T.any isAlpha w)

-- | Whether a statement finished. Under a grammar with maxLength a model
-- that starts a long sentence is cut off rather than steered: measured
-- 2026-09-26, a claim came back ending in the word "maintaining". Half a
-- sentence reads like a claim until its last word.
endsSentence :: Text -> Bool
endsSentence t = case T.unsnoc (T.stripEnd t) of
  Just (_, c) -> c `elem` ('.' : "!?")
  Nothing -> False

-- | Runs of whitespace collapsed to one space, so a quote copied across a
-- line break or with the indentation dropped still matches.
normalise :: Text -> Text
normalise = T.unwords . T.words

-- | Whether a line is a comment, by the markers the languages here use.
-- Nix and shell use #, Haskell and PureScript use --, and a Nix module's
-- option descriptions are prose in quotes, which count as code: a claim
-- resting on one is a reading of the file rather than a statement it makes
-- about itself.
isCommentLine :: Text -> Bool
isCommentLine l =
  let t = T.stripStart l
   in T.isPrefixOf "#" t || T.isPrefixOf "--" t || T.isPrefixOf "*" t

-- | Run every check over every claim, against the subjects the caller
-- supplied. Checks run cheapest first and the first failure decides.
verify :: [Subject] -> [RawClaim] -> Verdict
verify subjects raws = go Set.empty raws (Verdict [] [])
  where
    table = Map.fromList [(s.name, s.source) | s <- subjects]

    -- The haystack every identifier in a statement is looked for in: the
    -- whole part, lower-cased, plus the subject names.
    --
    -- Substring rather than token membership, and case-insensitive, after
    -- 2026-09-26: tokenising the source rejected "OpenSSL" against a source
    -- saying "openssl", and "homebeacon-key.pem" against
    -- "$out/homebeacon-key.pem". Both claims were true. The looser test
    -- still catches what matters: the same run caught "NixOS" and
    -- "non-zero", neither of which occurs in the bundle.
    haystack = T.toLower (T.intercalate "\n" (map (.source) subjects <> map (.name) subjects))

    isKnown w = T.isInfixOf (T.toLower w) haystack

    go _ [] v = v {accepted = reverse v.accepted, rejected = reverse v.rejected}
    go seen (r : rest) v = case check seen r of
      Left why -> go seen rest v {rejected = (r, why) : v.rejected}
      Right c -> go (Set.insert (fingerprint r) seen) rest v {accepted = c : v.accepted}

    fingerprint r = T.toLower (T.filter isAlphaNum r.statement)

    check seen r
      | Set.member (fingerprint r) seen = Left "duplicate of an earlier claim"
      | T.null (T.strip r.statement) = Left "empty statement"
      | not (endsSentence r.statement) =
          Left "the statement was cut off before its end, so the schema's length bound is too tight for what it tried to say"
      | otherwise = case Map.lookup r.subject table of
          Nothing -> Left ("subject " <> r.subject <> " is not one of the subjects for this part")
          Just src -> do
            ev <- locate src r.quotes
            let unknown = filter (not . isKnown) (Set.toList (identifiersIn r.statement))
                conf = if any (.inComment) ev then Stated else Inferred
            if not (null unknown)
              then Left ("the statement names " <> T.intercalate ", " (take 4 unknown) <> ", which appears nowhere in this part")
              else do
                aptness ev r
                -- A reason is the text's reason, never the model's, and
                -- now it cannot be relabelled into existence: a reason is
                -- accepted only when its evidence came from a comment.
                if r.kind == Reason && conf /= Stated
                  then Left "a reason must be quoted from a comment, not read off the code"
                  else
                    Right
                      Claim
                        { subject = r.subject
                        , kind = r.kind
                        , evidence = ev
                        , statement = T.strip r.statement
                        , confidence = conf
                        , passed = ["subjectKnown", "statementComplete", "evidenceResolves", "evidenceIsApt", "identifiersKnown", "reasonIsStated", "notDuplicate"]
                        }

    -- A quote must share at least one code-shaped name with its statement,
    -- when the statement has any. Measured 2026-09-26: a claim about the
    -- fields of a signed message cited "The signed message is exactly:",
    -- the colon-ended line ANNOUNCING the format rather than the format.
    -- True statement, evidence that shows nothing.
    aptness ev r =
      let inStatement = identifiersIn r.statement
          -- Substring, not token equality, for the same reason the
          -- identifier check uses it: the quote holds
          -- "$out/homebeacon-pub.pem" where the statement says
          -- "homebeacon-pub.pem", and tokenising rejected a true claim.
          quoted = T.toLower (T.intercalate "\n" (map (.quote) ev))
          shared = any (\w -> T.isInfixOf (T.toLower w) quoted) (Set.toList inStatement)
       in if Set.null inStatement || shared
            then Right ()
            else
              Left
                ( "the quote shares no name with the statement, so it does not show what the claim says ("
                    <> T.intercalate ", " (take 3 (Set.toList inStatement))
                    <> " appear in the statement, none in the quote)"
                )

    locate _ [] = Left "no evidence quoted"
    locate src qs = traverse (one src) qs

    -- A quote matches when its normalised form occurs in the normalised
    -- source. Two concessions, both measured against real rejections,
    -- neither weakening the guarantee that the words came from the text:
    -- whitespace is normalised, because a model reflows a quote that
    -- crossed a line break; and a quote ending in an ellipsis is matched by
    -- its prefix, because models abbreviate whatever the instruction says,
    -- with at least twenty characters left so "a..." matches nothing.
    --
    -- Still rejected, across four runs: an invented second openssl call
    -- (three times, the most stable model failure here), a quote missing
    -- the closing brace of a Nix escape, and a quote taken from a
    -- different file in the same bundle.
    one src q =
      let src' = normalise src
          q0 = normalise (T.strip q)
          trimmed = T.dropWhileEnd (\c -> c == '.' || c == '\8230' || isSpace c) q0
          candidates = [q0] <> [trimmed | trimmed /= q0, T.length trimmed >= 20]
          -- Which line the quote came from, for the comment test. The
          -- normalised offsets cannot index the original, so the line is
          -- found by searching the original lines for the quote's first
          -- twenty characters.
          probe c = T.take 20 c
          fromComment c = any (\l -> T.isInfixOf (probe c) (normalise l) && isCommentLine l) (T.lines src)
       in case [(c, before) | c <- candidates, not (T.null c), let (before, after) = T.breakOn c src', not (T.null after)] of
            ((c, before) : _) ->
              Right
                Evidence
                  { quote = c
                  , start = T.length before
                  , end = T.length before + T.length c
                  , inComment = fromComment c
                  }
            [] ->
              if T.null q0
                then Left "an empty quote"
                else Left ("the quote " <> ellipsis q0 <> " does not occur in the source")

    ellipsis q = "\"" <> (if T.length q > 60 then T.take 57 q <> "..." else q) <> "\""

-- ---------------------------------------------------------------------------
-- Rendering

-- | The document, written here rather than by the model. Two runs with the
-- same claims produce identical text, which is what makes a golden set
-- meaningful.
renderClaims :: [Subject] -> [Claim] -> Text
renderClaims subjects cs = T.intercalate "\n" (map one subjects)
  where
    one s =
      T.unlines
        ( ["## " <> s.name, ""]
            <> concatMap (section s.name) [minBound .. maxBound]
        )
    section subj k =
      case [c | c <- sortOn (.statement) cs, c.subject == subj, c.kind == k] of
        [] -> []
        found ->
          ["### " <> heading k, ""]
            <> [ "- " <> c.statement <> marker c.confidence
               | c <- found
               ]
            <> [""]
    marker = \case
      Stated -> ""
      Inferred -> " [inferred]"
    heading = \case
      Purpose -> "Purpose"
      Interface -> "Interface"
      Behaviour -> "Behaviour"
      Reason -> "Reasoning the text gives"
      OpenIssue -> "Marked as open"