-- | Reading a chase bundle, and pairing its skeletons with the source they
-- were derived from.
--
-- ============================================================================
-- WHY BOTH
-- ============================================================================
--
-- A chase skeleton carries what a parser can derive and a model should
-- never guess: the module's imports, its data declarations, every top-level
-- signature, the invariants already recorded, the decisions, the open
-- issues. A model given that does not have to infer arity, effects or what
-- a function returns, because those are in front of it.
--
-- The skeleton cannot be the evidence, though. Its ! lines are prose
-- someone (or some model) wrote, and a quote from them proves nothing about
-- the code. So a request carries the skeleton as structure and the module's
-- real source as the thing to quote from, and a claim's evidence is
-- checked against the source alone.
--
-- ============================================================================
-- THE TWO FORMATS
-- ============================================================================
--
-- A bundle is blocks separated by "=== BEGIN <path> ===", each holding
-- %file, %mod, %uses, data declarations, signatures with indented ! and ?
-- lines under them, and %decision / %open_issue blocks.
--
-- A source dump is files separated by "-- FILE: <path>", which is what
-- the project's own dumper emits.
--
-- Nothing here parses Haskell. A declaration's source is sliced by column:
-- from the line where its signature starts, to the next line that starts in
-- column zero and begins a different declaration. That is enough to give a
-- model the body of one function, and it is exact about where it stops
-- being exact.
module OpenSlop.Chase
  ( ChaseModule (..)
  , Decl (..)
  , parseBundle
  , parseSourceDump
  , declSource
  , modulesWithSource
  ) where

import Data.Char (isAlpha, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

-- | One declaration as the skeleton describes it.
data Decl = Decl
  { name :: Text
  , signature :: Text
  -- ^ the whole signature line, "name :: Type"
  , facts :: [Text]
  -- ^ the ! lines already recorded under it, which a new claim must not
  -- repeat
  }
  deriving stock (Show, Eq)

data ChaseModule = ChaseModule
  { path :: Text
  -- ^ as the bundle names it, e.g. Pelotero/DB/Pool.hs
  , moduleName :: Text
  , skeleton :: Text
  -- ^ the whole block, which is what goes in the prompt as structure
  , decls :: [Decl]
  }
  deriving stock (Show, Eq)

-- | Split a bundle into its blocks.
parseBundle :: Text -> [ChaseModule]
parseBundle = mapMaybe block . drop 1 . T.splitOn "=== BEGIN "
  where
    block b =
      case T.breakOn " ===" b of
        (p, rest)
          | T.null rest -> Nothing
          | otherwise ->
              let body = T.drop 4 rest
               in Just
                    ChaseModule
                      { path = T.strip p
                      , moduleName = fromMaybe "" (firstAfter "%mod " body)
                      , skeleton = T.strip body
                      , decls = signatures body
                      }
    firstAfter marker body =
      case [T.strip (T.drop (T.length marker) l) | l <- T.lines body, marker `T.isPrefixOf` l] of
        (x : _) -> Just x
        [] -> Nothing

-- | Signatures in a block, with the ! lines indented under each.
--
-- A signature is a line in column zero containing " :: " whose first word
-- is a plain identifier. That excludes "data", "instance", "type" and the
-- %directives, and it accepts operators only when they are named in
-- parentheses, which is what the skeleton writes.
signatures :: Text -> [Decl]
signatures body = go (T.lines body)
  where
    go [] = []
    go (l : ls)
      | Just (n, sig) <- asSignature l =
          let (indented, rest) = span isIndented ls
           in Decl {name = n, signature = sig, facts = [T.strip x | x <- indented, T.isPrefixOf "!" (T.stripStart x)]} : go rest
      | otherwise = go ls
    isIndented x = T.null (T.strip x) || isSpace (T.head x)
    asSignature l = do
      (lhs, _) <- pairOf (T.breakOn " :: " l)
      let n = T.strip lhs
      if not (T.null n) && not (isSpace (T.head l)) && plausible n
        then Just (n, T.strip l)
        else Nothing
    pairOf (a, b) = if T.null b then Nothing else Just (a, b)
    plausible n =
      let h = T.head n
       in (isAlpha h || h == '(' || h == '_')
            && n `notElem` (["data", "type", "newtype", "class", "instance"] :: [Text])

-- | Split a "-- FILE: path" dump into path-to-source.
parseSourceDump :: Text -> Map Text Text
parseSourceDump t = Map.fromList (go Nothing [] (T.lines t))
  where
    go current acc [] = close current acc
    go current acc (l : ls) = case T.stripPrefix "-- FILE: " l of
      Just p -> close current acc <> go (Just (T.strip p, [])) [] ls
      Nothing -> case current of
        Nothing -> go Nothing acc ls
        Just (p, body) -> go (Just (p, l : body)) acc ls
    close Nothing _ = []
    close (Just (p, body)) _ = [(p, T.unlines (reverse body))]

-- | The source of one declaration: from its signature line to the line
-- before the next one that starts in column zero and is not part of it.
--
-- Deliberately crude, and honest about it: a where-clause stays with its
-- function because it is indented, and a following comment block in column
-- zero ends the slice. A model reading this sees one function's body.
declSource :: Text -> Text -> Text
declSource decl src =
  let ls = T.lines src
      isStart l = T.isPrefixOf (decl <> " ") l || T.isPrefixOf (decl <> "::") l || T.isPrefixOf (decl <> " ::") l
      isTop l = not (T.null l) && not (isSpace (T.head l))
   in case break isStart ls of
        (_, []) -> ""
        (_, first : rest) ->
          let body = takeWhile (\l -> not (isTop l) || T.isPrefixOf (decl <> " ") l) rest
           in T.unlines (first : body)

-- | Modules from a bundle that also appear in a source dump, paired. The
-- bundle's path is absolute or repo-relative and the dump's is
-- repo-relative, so they are matched on a common suffix.
modulesWithSource :: [ChaseModule] -> Map Text Text -> [(ChaseModule, Text)]
modulesWithSource ms srcs =
  [ (m, s)
  | m <- ms
  , Just s <- [lookupBySuffix m.path]
  ]
  where
    lookupBySuffix p =
      case [v | (k, v) <- Map.toList srcs, p `T.isSuffixOf` k || k `T.isSuffixOf` p] of
        (v : _) -> Just v
        [] -> Nothing
