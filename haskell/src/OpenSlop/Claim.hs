-- | Claims: what a model is allowed to say about source text, and the
-- checks that decide whether it said it.
--
-- ============================================================================
-- THE MODEL POINTS, IT DOES NOT COMPOSE
-- ============================================================================
--
-- A claim names a subject drawn from a list the caller supplies, quotes the
-- source verbatim as its evidence, and adds one sentence. Everything else
-- about it is closed: the kind and the confidence are enums, so the
-- grammar the server decodes under cannot produce anything else, and the
-- subject is an enum too, so a file or a symbol that does not exist is not
-- a reachable token.
--
-- Evidence is quoted text rather than byte offsets. A model cannot count
-- bytes, and asking it to invites a plausible number that points at the
-- wrong line. A quote either occurs in the source or it does not, which is
-- a substring search, and the offsets are then recovered here.
--
-- ============================================================================
-- WHAT EACH CHECK CATCHES
-- ============================================================================
--
--   subjectKnown     a claim about something that is not in this part
--   evidenceResolves a quote that is not in the source, which is the
--                    signature of an invented fact
--   identifiersKnown a statement naming a function, option or unit that
--                    appears nowhere in the source: the most common and
--                    most damaging failure mode, caught by a substring test
--   notDuplicate     the same claim twice, which small models do under a
--                    schema that asks for a list
--
-- Nothing here judges whether a claim is TRUE. These checks remove claims
-- that cannot be true. What survives is for a person, or for a second
-- model, to read.
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
import Data.Char (isAlpha, isAlphaNum, isUpper)
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

data Confidence = Stated | Inferred | Unclear
  deriving stock (Show, Eq, Ord, Enum, Bounded)

confidenceText :: Confidence -> Text
confidenceText = \case
  Stated -> "stated"
  Inferred -> "inferred"
  Unclear -> "unclear"

instance ToJSON Confidence where
  toJSON = toJSON . confidenceText

instance FromJSON Confidence where
  parseJSON = withText "confidence" \t ->
    case [c | c <- [minBound .. maxBound], confidenceText c == t] of
      (c : _) -> pure c
      [] -> fail ("unknown confidence " <> T.unpack t)

-- | Exactly what the model returns. Every field is either closed or
-- checkable.
data RawClaim = RawClaim
  { subject :: Text
  , kind :: ClaimKind
  , quotes :: [Text]
  , statement :: Text
  , confidence :: Confidence
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A quote, located.
data Evidence = Evidence
  { quote :: Text
  , start :: Int
  , end :: Int
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
-- minItems and maxItems on the array are what make coverage a property of
-- the grammar rather than a warning afterwards: measured 2026-09-26, the
-- same model that documented one file of two without them documented both
-- with them. The caller passes the bounds it wants.
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
                                  , "maxItems" .= (3 :: Int)
                                  , "items" .= object ["type" .= ("string" :: Text)]
                                  ]
                            , "statement" .= object ["type" .= ("string" :: Text)]
                            , "confidence" .= object ["type" .= ("string" :: Text), "enum" .= map confidenceText [minBound .. maxBound]]
                            ]
                      , "required" .= (["subject", "kind", "quotes", "statement", "confidence"] :: [Text])
                      , "additionalProperties" .= False
                      ]
                ]
          ]
    , "required" .= (["claims"] :: [Text])
    , "additionalProperties" .= False
    ]

-- ---------------------------------------------------------------------------
-- The checks

-- | Tokens in a sentence that look like code rather than English, so that
-- a statement can be checked against the source without every ordinary
-- word being flagged.
--
-- A token counts when it carries a separator (a dot, slash, dash,
-- underscore, colon or at-sign), has an inner capital (camelCase), or is
-- shouted (all capitals). An English word in lower case never does, which
-- is what makes the check usable on prose. Trailing punctuation is
-- stripped, since a model writes "foo.bar." at the end of a sentence.
identifiersIn :: Text -> Set Text
identifiersIn t =
  Set.fromList
    [ w
    | raw <- T.split (\c -> c == ' ' || c == '\n' || c == '\t' || c == ',' || c == '(' || c == ')' || c == '"' || c == '`' || c == '\'') t
    , let w = T.dropAround (`elem` (".,;:!?" :: String)) raw
    , T.length w > 2
    , codeLike w
    ]
  where
    codeLike w =
      T.any (`elem` ("._-/:@" :: String)) (T.drop 1 (T.init w))
        || T.any isUpper (T.drop 1 w)
        || (T.all (\c -> isUpper c || not (isAlpha c)) w && T.any isAlpha w)

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
    -- 2026-09-26: tokenising the source rejected "OpenSSL" because the
    -- source says "openssl", and rejected "homebeacon-key.pem" because the
    -- source says "$out/homebeacon-key.pem" and the tokeniser kept the
    -- prefix. Both claims were true. The looser test still catches the
    -- failure that matters, a name that is nowhere in the text at all.
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
      | otherwise = case Map.lookup r.subject table of
          Nothing -> Left ("subject " <> r.subject <> " is not one of the subjects for this part")
          Just src -> do
            ev <- locate src r.quotes
            let unknown = filter (not . isKnown) (Set.toList (identifiersIn r.statement))
            if not (null unknown)
              then Left ("the statement names " <> T.intercalate ", " (take 4 unknown) <> ", which appears nowhere in this part")
              else
                Right
                  Claim
                    { subject = r.subject
                    , kind = r.kind
                    , evidence = ev
                    , statement = T.strip r.statement
                    , confidence = r.confidence
                    , passed = ["subjectKnown", "evidenceResolves", "identifiersKnown", "notDuplicate"]
                    }

    locate _ [] = Left "no evidence quoted"
    locate src qs = traverse (one src) qs

    one src q =
      let q' = T.strip q
       in if T.null q'
            then Left "an empty quote"
            else case T.breakOn q' src of
              (before, after)
                | T.null after -> Left ("the quote " <> ellipsis q' <> " does not occur in the source")
                | otherwise -> Right Evidence {quote = q', start = T.length before, end = T.length before + T.length q'}

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
      Unclear -> " [unclear]"
    heading = \case
      Purpose -> "Purpose"
      Interface -> "Interface"
      Behaviour -> "Behaviour"
      Reason -> "Reasoning the text gives"
      OpenIssue -> "Marked as open"