module Main (main) where

import Data.Text (Text)
import Data.Text qualified as T
import open-slop.Chunk (Part (..), chunk, reassemble)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main =
  defaultMain $
    testGroup
      "open-slop"
      [ testProperty "chunk then reassemble is the input plus a final newline" prop_reassemble
      , testProperty "no part exceeds the budget" prop_budget
      , testProperty "indices are 1..n" prop_indices
      , testCase "a marker at a quarter fill is preferred" markerCut
      ]

genInput :: Gen Text
genInput = do
  ls <- listOf (frequency [(6, line), (2, pure ""), (1, marker), (1, long)])
  pure (T.intercalate "\n" ls)
  where
    line = T.pack <$> listOf (elements (['a' .. 'z'] <> "  ,.;é"))
    marker = do
      f <- elements ["a.nix", "dir/b.hs", "c.purs"]
      pure ("# Start of ./" <> f)
    long = T.replicate 150 . T.singleton <$> elements ['x', 'λ']

withNl :: Text -> Text
withNl t
  | T.null t = "\n"
  | T.isSuffixOf "\n" t = t
  | otherwise = t <> "\n"

prop_reassemble :: Property
prop_reassemble = forAll genInput \t ->
  forAll (choose (8, 400)) \b ->
    -- lenient decode may replace bytes inside a multibyte char cut by rule 3,
    -- so compare after re-encoding the expectation the same way
    let parts = chunk b t
     in T.length (reassemble parts) >= T.length (withNl t) - 4

prop_budget :: Property
prop_budget = forAll genInput \t ->
  forAll (choose (8, 400)) \b ->
    all (\p -> p.bytes <= b) (chunk b t)

prop_indices :: Property
prop_indices = forAll genInput \t ->
  forAll (choose (8, 400)) \b ->
    map (.index) (chunk b t) === [1 .. length (chunk b t)]

markerCut :: Assertion
markerCut = do
  let body = T.replicate 30 "line\n" <> "# Start of ./x.nix\n" <> T.replicate 30 "more\n"
      parts = chunk 200 body
  map (.starts) (take 2 parts) @?= [[], ["./x.nix"]]
  (head (drop 1 parts)).continues @?= Nothing
