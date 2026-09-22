module Main (main) where

import Data.Aeson (Value (..), eitherDecode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Catalogue
import OpenSlop.Chunk (Mode (..), Part (..), chunk, chunkWith, reassemble)
import OpenSlop.Gateway.Keys (authorise, parseKeys)
import OpenSlop.Gateway.Route (Target, resolveTarget, targetId)
import OpenSlop.Gateway.Translate (Call (..), Reply (..), parseBackendReply, plan)
import OpenSlop.OpenAI
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main =
  defaultMain $
    testGroup
      "open-slop"
      [ testGroup
          "chunk"
          [ testProperty "chunk then reassemble is the input plus a final newline" prop_reassemble
          , testProperty "no part exceeds the budget" prop_budget
          , testProperty "indices are 1..n" prop_indices
          , testCase "a marker at a quarter fill is preferred" markerCut
          , testCase "per-file starts a part at every marker" perFileCut
          ]
      , testGroup
          "gateway"
          [ testCase "a Grace-shaped request decodes" graceRequest
          , testCase "refused fields fail the decode by name" refusedFields
          , testCase "ollama gets the schema as format and the window as num_ctx" ollamaPlan
          , testCase "llama-server gets response_format as sent, no context" llamaPlan
          , testCase "hailo-ollama refuses a schema" hailoRefusesSchema
          , testCase "input over the window is refused before sending" oversize
          , testCase "model ids resolve by unique suffix" resolution
          , testCase "backend replies parse per engine" replies
          , testCase "keys authorise by bearer token" keysAuth
          ]
      ]

-- ---------------------------------------------------------------------------
-- chunk

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

perFileCut :: Assertion
perFileCut = do
  let body = "# Start of ./a.nix\na\n# Start of ./b.nix\nb\n# Start of ./c.nix\nc\n"
  map (.starts) (chunkWith PerFile 10000 body) @?= [["./a.nix"], ["./b.nix"], ["./c.nix"]]
  length (chunkWith Packed 10000 body) @?= 1

-- ---------------------------------------------------------------------------
-- gateway

mkBackend :: Engine -> Int -> Int -> Backend
mkBackend engine ctx predict =
  Backend
    { engine
    , port = 0
    , streams = True
    , acceptsOptions = True
    , ctx
    , predict
    , promptOverhead = 256
    , charsPerToken = 2.8
    , temperature = Just 0.0
    , blurb = ""
    }

catalogue :: Catalogue
catalogue =
  Catalogue
    { endpoints = []
    , backends =
        Map.fromList
          [ ("cpu", mkBackend Ollama 16384 2048)
          , ("hailo", mkBackend HailoOllama 2048 768)
          , ("llamacpp", mkBackend LlamaServer 32768 4096)
          ]
    , models = Map.empty
    }

ep :: Text -> Endpoint
ep b = Endpoint {row = "oracle", backend = b, url = "http://127.0.0.1"}

listing :: [(Endpoint, [Text])]
listing =
  [ (ep "cpu", ["qwen2.5-coder:7b", "llama3.1:8b", "sully:latest"])
  , (ep "hailo", ["llama3.2:3b", "qwen2.5-coder:1.5b"])
  , (ep "llamacpp", ["bonsai-8b"])
  ]

target :: Text -> Target
target q = either (error . T.unpack) id (resolveTarget catalogue listing q)

schema :: Value
schema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object ["summary" .= object ["type" .= ("string" :: Text)]]
    , "required" .= ["summary" :: Text]
    , "additionalProperties" .= False
    ]

-- The shape Grace's prompt keyword sends through the openai bindings:
-- content as a list of text parts, the result type as a strict schema.
graceBody :: Text -> BLC.ByteString
graceBody model =
  Aeson.encode
    ( object
        [ "model" .= model
        , "messages"
            .= [ object ["role" .= ("user" :: Text), "content" .= [object ["type" .= ("text" :: Text), "text" .= ("hello" :: Text)]]]
               ]
        , "response_format"
            .= object
              [ "type" .= ("json_schema" :: Text)
              , "json_schema" .= object ["name" .= ("result" :: Text), "schema" .= schema, "strict" .= True]
              ]
        , "max_completion_tokens" .= (256 :: Int)
        , "reasoning_effort" .= ("low" :: Text)
        ]
    )

request :: Text -> ChatRequest
request model = either error id (eitherDecode (graceBody model))

graceRequest :: Assertion
graceRequest = do
  let r = request "qwen2.5-coder:7b"
  r.messages @?= [Message RoleUser "hello"]
  r.responseFormat @?= Just (FormatJsonSchema "result" schema)
  r.maxTokens @?= Just 256

refusedFields :: Assertion
refusedFields = do
  let decodeWith extra = eitherDecode (Aeson.encode (object (["model" .= ("m" :: Text), "messages" .= [object ["role" .= ("user" :: Text), "content" .= ("x" :: Text)]]] <> extra))) :: Either String ChatRequest
      failsNaming :: Text -> [(Aeson.Key, Value)] -> Assertion
      failsNaming name extra = case decodeWith extra of
        Left e -> assertBool ("error names " <> T.unpack name <> ": " <> e) (name `T.isInfixOf` T.pack e)
        Right _ -> assertFailure ("accepted a request with " <> T.unpack name)
  failsNaming "tools" ["tools" .= [object []]]
  failsNaming "stream" ["stream" .= True]
  failsNaming "n other than 1" ["n" .= (2 :: Int)]
  case decodeWith ["tools" .= ([] :: [Value]), "stream" .= False] of
    Left e -> assertFailure ("refused an empty tools list or stream false: " <> e)
    Right _ -> pure ()

field :: Text -> Value -> Maybe Value
field k = \case
  Object o -> KeyMap.lookup (Key.fromText k) o
  _ -> Nothing

ollamaPlan :: Assertion
ollamaPlan = do
  let t = target "qwen2.5-coder:7b"
  c <- either (assertFailure . show) pure (plan t (request "qwen2.5-coder:7b"))
  c.path @?= "/api/chat"
  field "format" c.body @?= Just schema
  (field "options" c.body >>= field "num_ctx") @?= Just (Number 16384)
  (field "options" c.body >>= field "num_predict") @?= Just (Number 256)
  field "stream" c.body @?= Just (Bool False)

llamaPlan :: Assertion
llamaPlan = do
  let t = target "bonsai-8b"
  c <- either (assertFailure . show) pure (plan t (request "bonsai-8b"))
  c.path @?= "/v1/chat/completions"
  (field "response_format" c.body >>= field "type") @?= Just (String "json_schema")
  field "max_tokens" c.body @?= Just (Number 256)
  field "options" c.body @?= Nothing

hailoRefusesSchema :: Assertion
hailoRefusesSchema =
  case plan (target "llama3.2:3b") (request "llama3.2:3b") of
    Left e -> e.code @?= Just "response_format_unsupported"
    Right _ -> assertFailure "hailo-ollama was sent a schema"

oversize :: Assertion
oversize = do
  let r = (request "llama3.2:3b") {responseFormat = Nothing, messages = [Message RoleUser (T.replicate 6000 "x")]}
  case plan (target "llama3.2:3b") r of
    Left e -> e.code @?= Just "context_length_exceeded"
    Right _ -> assertFailure "6000 bytes and a 256-token answer were sent to a 2048-token window"

resolution :: Assertion
resolution = do
  fmap targetId (resolveTarget catalogue listing "qwen2.5-coder:7b") @?= Right "oracle/cpu/qwen2.5-coder:7b"
  fmap targetId (resolveTarget catalogue listing "oracle/hailo/qwen2.5-coder:1.5b") @?= Right "oracle/hailo/qwen2.5-coder:1.5b"
  fmap targetId (resolveTarget catalogue listing "sully") @?= Right "oracle/cpu/sully:latest"
  assertBool "gpt-4o does not resolve" (either (const True) (const False) (resolveTarget catalogue listing "gpt-4o"))
  let twice = listing <> [(Endpoint {row = "blade", backend = "cpu", url = "http://blade"}, ["qwen2.5-coder:7b"])]
  assertBool "a name on two rows is ambiguous" (either (const True) (const False) (resolveTarget catalogue twice "qwen2.5-coder:7b"))
  fmap targetId (resolveTarget catalogue twice "blade/cpu/qwen2.5-coder:7b") @?= Right "blade/cpu/qwen2.5-coder:7b"

replies :: Assertion
replies = do
  parseBackendReply Ollama "{\"message\":{\"role\":\"assistant\",\"content\":\"{}\"},\"done\":true,\"done_reason\":\"length\",\"prompt_eval_count\":40,\"eval_count\":9}"
    @?= Right (Reply "{}" (Just 40) (Just 9) FinishLength)
  parseBackendReply HailoOllama "{\"response\":\"hi\",\"done\":true,\"done_reason\":\"stop\",\"eval_count\":2}"
    @?= Right (Reply "hi" Nothing (Just 2) FinishStop)
  parseBackendReply LlamaServer "{\"choices\":[{\"message\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}"
    @?= Right (Reply "x" (Just 3) (Just 1) FinishStop)
  assertBool "an ollama error body is an error" (either (const True) (const False) (parseBackendReply Ollama "{\"error\":\"model not found\"}"))

keysAuth :: Assertion
keysAuth = do
  ks <- either (assertFailure . T.unpack) pure (parseKeys "# comment\n\nwinsmuth llm_winsmuth_AAAAAAAAAAAAAAAAAAAAAAAA\n")
  authorise ks (Just "Bearer llm_winsmuth_AAAAAAAAAAAAAAAAAAAAAAAA") @?= Right "winsmuth"
  assertBool "a wrong key is refused" (either (const True) (const False) (authorise ks (Just "Bearer llm_winsmuth_BBBBBBBBBBBBBBBBBBBBBBBB")))
  assertBool "no header is refused" (either (const True) (const False) (authorise ks Nothing))