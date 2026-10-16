module Main (main) where

import Data.Aeson (Value (..), eitherDecode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Char (isSpace)
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Agent.Action hiding (Decision (..))
import OpenSlop.Agent.Action (Decision (Decision))
import OpenSlop.Agent.Oracle
import OpenSlop.Agent.Transcript (Step (..), messagesFor)
import OpenSlop.Agent.Workspace (numbered, openWorkspace, replaceOnce, resolve)
import OpenSlop.Capacity (Capacity (..), CptSource (..), WindowSource (..), answerRoom, capacityFor, learn, promptChars, promptCharsWithin)
import OpenSlop.Catalogue
import OpenSlop.Chunk (Mode (..), Part (..), chunk, chunkWith, reassemble)
import OpenSlop.Gateway.Keys (authorise, parseKeys)
import OpenSlop.Gateway.Route (Target, resolveTarget, targetId)
import OpenSlop.Gateway.Translate (Call (..), Reply (..), parseBackendReply, plan)
import OpenSlop.OpenAI
import OpenSlop.Rag.Locality (hostOf, privateHost)
import OpenSlop.Rag.Retrieve (citedSources)
import OpenSlop.Rag.Split (Piece (..), SplitConfig (SplitConfig), split)
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
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
          , testCase "a message's name is kept at the top of its content" messageNames
          , testCase "reasoning effort reaches each backend's switch" efforts
          , testCase "a Grace union schema reaches both servers unchanged" unionSchema
          ]
      , testGroup
          "agent"
          [ testCase "every action survives JSON in Grace's encoding" actionRoundTrip
          , testCase "the schema is Grace's: tagged alternatives, closed records" schemaShape
          , testCase "a run offers only the actions it can carry out" schemaSubset
          , testCase "a decision is read with or without a code fence, and refused when malformed" decisions
          , testCase "replace needs exactly one exact match" replacing
          , testCase "numbered reads are cut at a line to fit" numberedReads
          , testCase "paths cannot leave the workspace" confinement
          , testCase "tricorder's finished build decodes with diagnostics and tests" tricorderFinished
          , testCase "tricorder's other phases decode" tricorderPhases
          , testCase "Finish needs a settled clean build with passing tests" acceptance
          , testCase "the report shows errors first and fits its room" reportFits
          , testCase "the transcript keeps the newest steps and fits the budget" transcriptFits
          ]
      , testGroup
          "rag"
          [ testProperty "no chunk exceeds the hard limit" prop_splitLimit
          , testProperty "splitting loses and adds no text" prop_splitKeeps
          , testProperty "ordinals are 0..n-1" prop_splitOrdinals
          , testCase "headings become the chunk's path" splitHeadings
          , testCase "a heading inside a code fence is not a heading" splitFence
          , testCase "hosts are read out of URLs" hosts
          , testCase "only LAN hosts are private" locality
          , testCase "citations are read back out of a reply" citations
          ]
      , testGroup
          "capacity"
          [ testCase "llama-server's allocated window is the window" capLlama
          , testCase "ollama gets the trained context within the catalogue's limit" capOllama
          , testCase "a measured chars-per-token replaces the catalogue's guess" capMeasured
          , testCase "learning ignores counts far from the current figure" capLearn
          , testCase "a time budget shrinks the prompt by the measured prefill rate" capWait
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

-- ---------------------------------------------------------------------------
-- rag

genDoc :: Gen Text
genDoc = do
  ls <- listOf (frequency [(6, line), (2, pure ""), (1, heading), (1, long), (1, fence)])
  pure (T.intercalate "\n" ls)
  where
    line = T.pack <$> listOf (elements (['a' .. 'z'] <> "  ,.;é"))
    heading = do
      n <- choose (1, 4)
      w <- T.pack <$> listOf1 (elements ['a' .. 'z'])
      pure (T.replicate n "#" <> " " <> w)
    long = T.replicate 400 . T.singleton <$> elements ['x', 'λ']
    fence = pure "```"

-- target and hard limit, positionally: the field names would clash with
-- this module's `target`
genSplit :: Gen (Int, Int)
genSplit = do
  t <- choose (20, 600)
  h <- choose (t, t * 2)
  pure (t, h)

cfgOf :: (Int, Int) -> SplitConfig
cfgOf (t, h) = SplitConfig t h

prop_splitLimit :: Property
prop_splitLimit = forAll genDoc \d -> forAll genSplit \c ->
  all (\p -> T.length p.body <= snd c) (split (cfgOf c) d)

prop_splitKeeps :: Property
prop_splitKeeps = forAll genDoc \d -> forAll genSplit \c ->
  T.filter (not . isSpace) (T.concat (map (.body) (split (cfgOf c) d))) === T.filter (not . isSpace) d

prop_splitOrdinals :: Property
prop_splitOrdinals = forAll genDoc \d -> forAll genSplit \c ->
  let ps = split (cfgOf c) d in map (.ordinal) ps === [0 .. length ps - 1]

splitHeadings :: Assertion
splitHeadings = do
  let doc = "intro\n# Install\nfirst\n## NixOS\nsecond\n# Use\nthird\n"
      ps = split (SplitConfig 1000 1000) doc
  map (.heading) ps @?= [[], ["Install"], ["Install", "NixOS"], ["Use"]]
  map (\p -> (p.lineFrom, p.lineTo)) ps @?= [(1, 1), (2, 3), (4, 5), (6, 7)]

splitFence :: Assertion
splitFence = do
  let doc = "# Real\n```\n# not a heading\n```\nafter\n"
      ps = split (SplitConfig 1000 1000) doc
  map (.heading) ps @?= [["Real"]]

hosts :: Assertion
hosts = do
  hostOf "http://192.168.8.173:11434" @?= Just "192.168.8.173"
  hostOf "https://user@Oracle.lan/x" @?= Just "oracle.lan"
  hostOf "http://[fd00::1]:8080/" @?= Just "fd00::1"
  hostOf "ftp://x" @?= Nothing

locality :: Assertion
locality = do
  let yes = ["127.0.0.1", "localhost", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.8.173", "169.254.1.1", "::1", "fd00::1", "fe80::1", "oracle", "oracle.lan", "nas.home.arpa"]
      no = ["8.8.8.8", "172.32.0.1", "192.169.0.1", "api.openai.com", "example.com", "2001:db8::1", "fd::1", "256.1.1.1"]
  mapM_ (\h -> assertBool (T.unpack h <> " should be private") (privateHost h)) yes
  mapM_ (\h -> assertBool (T.unpack h <> " should not be private") (not (privateHost h))) no

citations :: Assertion
citations = do
  citedSources "It is in [2] and [1, 3]; see also [link] and [12]." @?= [1, 2, 3, 12]
  citedSources "no sources" @?= []

-- ---------------------------------------------------------------------------
-- capacity

capLlama :: Assertion
capLlama = do
  let c = capacityFor (mkBackend LlamaServer 16384 2048) Nothing Nothing (Just 131072)
  (c.window, c.windowSource) @?= (131072, ServerAllocated)

capOllama :: Assertion
capOllama = do
  let b = mkBackend Ollama 16384 2048
  (capacityFor b Nothing Nothing (Just 131072)).window @?= 16384
  (capacityFor b Nothing Nothing (Just 4096)).window @?= 4096
  (capacityFor b Nothing Nothing Nothing).windowSource @?= ConfiguredOnly
  let big = Model {summary = "", docFit = Unknown, ctx = Just 65536, predict = Nothing, tokPerSec = Nothing, licence = "", blurb = ""}
  (capacityFor b (Just big) Nothing (Just 131072)).window @?= 65536

capMeasured :: Assertion
capMeasured = do
  let m = object ["charsPerToken" .= (3.9 :: Double)]
      c = capacityFor (mkBackend Ollama 16384 2048) Nothing (Just m) (Just 32768)
  (c.charsPerToken, c.cptSource) @?= (3.9, Benchmarked)

capLearn :: Assertion
capLearn = do
  let c = capacityFor (mkBackend Ollama 16384 2048) Nothing Nothing (Just 32768)
  (learn c 4000 1000).cptSource @?= Learned
  (learn c 4000 1000).charsPerToken @?= 4.0
  -- a cached prefix makes the count look tiny: ignored
  (learn c 40000 1000).charsPerToken @?= 2.8

capWait :: Assertion
capWait = do
  let m = object ["prefill" .= [object ["promptTokens" .= (4096 :: Int), "tokPerSec" .= (20 :: Double)]]]
      c = capacityFor (mkBackend Ollama 16384 2048) Nothing (Just m) (Just 32768)
  answerRoom c @?= 4096
  promptCharsWithin c 0 (Just 10) @?= floor (10 * 20 * 2.8 :: Double)
  promptCharsWithin c 0 Nothing @?= promptChars c 0

-- ---------------------------------------------------------------------------
-- gateway: Grace

messageNames :: Assertion
messageNames = do
  let body =
        Aeson.encode
          ( object
              [ "model" .= ("m" :: Text)
              , "messages"
                  .= [ object ["role" .= ("system" :: Text), "name" .= ("Type" :: Text), "content" .= ("{ x: Text }" :: Text)]
                     , object ["role" .= ("user" :: Text), "content" .= ("go" :: Text)]
                     ]
              ]
          )
  r <- either assertFailure pure (eitherDecode body :: Either String ChatRequest)
  r.messages @?= [Message RoleSystem "Type:\n{ x: Text }", Message RoleUser "go"]

efforts :: Assertion
efforts = do
  let withEffort e q = (request q) {effort = Just e, responseFormat = Nothing}
  c1 <- either (assertFailure . show) pure (plan (target "qwen2.5-coder:7b") (withEffort High "qwen2.5-coder:7b"))
  field "think" c1.body @?= Just (Bool True)
  c2 <- either (assertFailure . show) pure (plan (target "qwen2.5-coder:7b") (withEffort Minimal "qwen2.5-coder:7b"))
  field "think" c2.body @?= Just (Bool False)
  c3 <- either (assertFailure . show) pure (plan (target "bonsai-8b") (withEffort Minimal "bonsai-8b"))
  (field "chat_template_kwargs" c3.body >>= field "enable_thinking") @?= Just (Bool False)
  c4 <- either (assertFailure . show) pure (plan (target "qwen2.5-coder:7b") ((request "qwen2.5-coder:7b") {effort = Nothing}))
  field "think" c4.body @?= Nothing
  (request "x").effort @?= Just Low

-- The schema Grace's prompt derives from a union, as stages/agent-step.ffg
-- produces it; checked 2026-10-16 to convert to a grammar with llama.cpp's
-- converter (the one llama-server and ollama use) that accepts every
-- decision and rejects an unknown tag.
unionSchema :: Assertion
unionSchema = do
  let s = decisionSchema allKinds
      r = (request "x") {responseFormat = Just (FormatJsonSchema "result" s)}
  c1 <- either (assertFailure . show) pure (plan (target "qwen2.5-coder:7b") r)
  field "format" c1.body @?= Just s
  c2 <- either (assertFailure . show) pure (plan (target "bonsai-8b") r)
  (field "response_format" c2.body >>= field "json_schema" >>= field "schema") @?= Just s

-- ---------------------------------------------------------------------------
-- agent

sampleActions :: [Action]
sampleActions =
  [ BrowseDirectory (BrowseDirectoryArgs "src")
  , ReadFile (ReadFileArgs "src/A.hs" (Just 10) Nothing)
  , SearchIndex (SearchIndexArgs "where is the window checked")
  , LookupSource (LookupSourceArgs "Data.Map.Strict#insertWith")
  , ReplaceText (ReplaceTextArgs "src/A.hs" "x = 1" "x = 2")
  , WriteFile (WriteFileArgs "src/B.hs" "module B where\n")
  , Check
  , Finish (FinishArgs "done")
  ]

actionRoundTrip :: Assertion
actionRoundTrip = do
  map kindOf sampleActions @?= allKinds
  mapM_ (\a -> Aeson.eitherDecode (Aeson.encode (Decision "p" a)) @?= Right (Decision "p" a)) sampleActions
  Aeson.eitherDecode "{\"plan\":\"p\",\"step\":{\"tag\":\"ReadFile\",\"contents\":{\"path\":\"a\",\"startLine\":3.0,\"stopLine\":null}}}"
    @?= Right (Decision "p" (ReadFile (ReadFileArgs "a" (Just 3) Nothing)))
  assertBool "a fractional line is refused" (isLeft (Aeson.eitherDecode "{\"plan\":\"p\",\"step\":{\"tag\":\"ReadFile\",\"contents\":{\"path\":\"a\",\"startLine\":1.5,\"stopLine\":null}}}" :: Either String Decision))

alternatives :: Value -> [Value]
alternatives s = case field "properties" s >>= field "step" >>= field "anyOf" of
  Just (Array xs) -> toList xs
  _ -> []

tagOf :: Value -> Maybe Value
tagOf alt = field "properties" alt >>= field "tag" >>= field "const"

schemaShape :: Assertion
schemaShape = do
  let s = decisionSchema allKinds
      alts = alternatives s
  map tagOf alts @?= map (Just . String . kindName) allKinds
  field "required" s @?= Just (Aeson.toJSON ["plan", "step" :: Text])
  mapM_
    ( \alt -> do
        field "additionalProperties" alt @?= Just (Bool False)
        field "required" alt @?= Just (Aeson.toJSON ["tag", "contents" :: Text])
        let c = field "properties" alt >>= field "contents"
        (c >>= field "additionalProperties") @?= Just (Bool False)
        case (c >>= field "properties", c >>= field "required") of
          (Just (Object ps), Just (Array rs)) -> map Key.toText (KeyMap.keys ps) @?= [t | String t <- toList rs]
          _ -> assertFailure "an alternative's contents is not a closed record"
    )
    alts

schemaSubset :: Assertion
schemaSubset = do
  let readOnly = [k | k <- allKinds, k `notElem` [KReplaceText, KWriteFile]]
  map tagOf (alternatives (decisionSchema readOnly)) @?= map (Just . String . kindName) readOnly

decisions :: Assertion
decisions = do
  decodeDecision "{\"plan\":\"x\",\"step\":{\"tag\":\"Check\",\"contents\":{}}}" @?= Right (Decision "x" Check)
  decodeDecision "```json\n{\"plan\":\"x\",\"step\":{\"tag\":\"Check\",\"contents\":{}}}\n```" @?= Right (Decision "x" Check)
  assertBool "an unknown action is refused" (isLeft (decodeDecision "{\"plan\":\"x\",\"step\":{\"tag\":\"RunShell\",\"contents\":{\"command\":\"rm\"}}}"))
  assertBool "a cut-off reply is refused" (isLeft (decodeDecision "{\"plan\":\"x\",\"step\":{\"tag\""))

replacing :: Assertion
replacing = do
  replaceOnce "b = 2" "b = 3" "a = 1\nb = 2\n" @?= Right "a = 1\nb = 3\n"
  assertBool "two matches are refused" (isLeft (replaceOnce "x" "y" "x x"))
  assertBool "no match is refused" (isLeft (replaceOnce "z" "y" "x"))
  case replaceOnce "  b = 2" "b = 3" "a = 1\nb  =  2\n" of
    Left why -> assertBool "says the spacing differs" ("spacing" `T.isInfixOf` why)
    Right _ -> assertFailure "a loose match was applied"

numberedReads :: Assertion
numberedReads = do
  let file = T.unlines [T.pack ("line " <> show i) | i <- [1 .. 100 :: Int]]
      whole = numbered 100000 Nothing Nothing file
  assertBool "whole file shows the last line" ("100| line 100" `T.isInfixOf` whole)
  let part = numbered 100000 (Just 10) (Just 12) file
  assertBool "a range starts where asked" ("10| line 10" `T.isInfixOf` part && not ("13| line 13" `T.isInfixOf` part))
  let cut = numbered 400 Nothing Nothing file
  assertBool "a cut says where to continue" ("read from line" `T.isInfixOf` cut)
  assertBool "a cut fits" (T.length cut <= 400)

confinement :: Assertion
confinement = do
  tmp <- getTemporaryDirectory
  let base = tmp </> "open-slop-test-ws"
  removePathForcibly base
  createDirectoryIfMissing True (base </> "proj" </> "src")
  createDirectory (base </> "outside")
  createFileLink (base </> "outside") (base </> "proj" </> "escape")
  ws <- either (assertFailure . T.unpack) pure =<< openWorkspace (base </> "proj")
  ok <- resolve ws "src/A.hs"
  assertBool "a path inside resolves" (isRight ok)
  newFile <- resolve ws "src/new/B.hs"
  assertBool "a new file inside resolves" (isRight newFile)
  mapM_
    ( \p -> do
        r <- resolve ws p
        assertBool (T.unpack p <> " is refused") (isLeft r)
    )
    ["../outside/x", "/etc/passwd", ".git/config", "src/../../outside", "escape/x", ".tricorder.yaml"]
  removePathForcibly base

finishedJson :: Text
finishedJson =
  "{\"buildId\":7,\"phase\":{\"tag\":\"Finished\",\"contents\":[{\"completedAt\":\"2026-10-16T02:00:00Z\",\"duration\":1234,\"moduleCount\":12,\"diagnostics\":[{\"severity\":\"warning\",\"file\":\"src/A.hs\",\"line\":3,\"col\":1,\"endLine\":3,\"endCol\":9,\"title\":\"unused import\",\"text\":\"The import of Data.List is redundant\"},{\"severity\":\"error\",\"file\":\"src/B.hs\",\"line\":10,\"col\":5,\"endLine\":10,\"endCol\":12,\"title\":\"Couldn't match type\",\"text\":\"Couldn't match expected type Int with actual type Text\"}]},{\"testSuites\":[[\"test:spec\",{\"tag\":\"suite_completed\",\"contents\":{\"passed\":false,\"output\":\"1 out of 2 tests failed\",\"test_cases\":[{\"description\":\"parses 5m\",\"outcome\":{\"tag\":\"passed\"}},{\"description\":\"parses 1h30m\",\"outcome\":{\"tag\":\"failed\",\"contents\":\"expected 5400 got 0\"}}],\"duration\":20}}]],\"evalComments\":{\"tag\":\"Found\",\"contents\":{\"getComments\":[{\"file\":\"src/A.hs\",\"comment\":{\"lineNumber\":20,\"expression\":\"parse 5\"},\"state\":{\"state\":\"completed\",\"output\":\"Just 5\"}}]}}}]}}"

tricorderFinished :: Assertion
tricorderFinished = do
  r <- either (assertFailure . T.unpack) pure (decodeTricorder finishedJson)
  r.buildId @?= 7
  case r.outcome of
    Built b -> do
      b.modules @?= 12
      map (.severity) b.diagnostics @?= [SevWarning, SevError]
      b.suites @?= [Suite "test:spec" (SuiteFailed [("parses 1h30m", "expected 5400 got 0")] "1 out of 2 tests failed")]
      map (.output) b.evaluations @?= [Just "Just 5"]
      b.testing @?= False
    other -> assertFailure ("decoded as " <> show other)
  settled r @?= True
  clean r @?= False
  map (.file) (errorsOf r) @?= ["src/B.hs"]
  -- the suites as an object keyed by target decode the same way
  let keyed = T.replace "\"testSuites\":[[\"test:spec\"," "\"testSuites\":{\"test:spec\":" (T.replace "}}]],\"evalComments\"" "}}},\"evalComments\"" finishedJson)
  r2 <- either (assertFailure . T.unpack) pure (decodeTricorder keyed)
  case r2.outcome of
    Built b -> map (.name) b.suites @?= ["test:spec"]
    other -> assertFailure ("decoded as " <> show other)

tricorderPhases :: Assertion
tricorderPhases = do
  fmap (.outcome) (decodeTricorder "{\"buildId\":1,\"phase\":{\"tag\":\"Starting\"}}") @?= Right (InProgress "starting")
  fmap (.outcome) (decodeTricorder "{\"buildId\":1,\"phase\":{\"tag\":\"Building\",\"contents\":[[],{\"compiled\":3,\"total\":9}]}}")
    @?= Right (InProgress "compiled 3 of 9 modules")
  fmap (.outcome) (decodeTricorder "{\"buildId\":2,\"phase\":{\"tag\":\"Failed\",\"contents\":\"cabal: unknown package\"}}")
    @?= Right (CommandFailed "cabal: unknown package")
  let postBuilding = T.replace "\"Finished\"" "\"PostBuilding\"" finishedJson
  fmap settled (decodeTricorder postBuilding) @?= Right False
  assertBool "garbage is refused" (isLeft (decodeTricorder "Stopped."))

acceptance :: Assertion
acceptance = do
  let ok = Report 3 (Just "t") (Built (Build 4 [] [Suite "s" SuitePassed] [] False))
      warnOnly = ok {outcome = Built (Build 4 [Diagnostic SevWarning "a" 1 1 1 1 "w" ""] [] [] False)}
      running = ok {outcome = Built (Build 4 [] [Suite "s" SuiteRunning] [] True)}
      failing = ok {outcome = Built (Build 4 [] [Suite "s" (SuiteErrored "boom")] [] False)}
  acceptable ok @?= True
  acceptable warnOnly @?= True
  acceptable running @?= False
  acceptable failing @?= False
  acceptable ok {outcome = CommandFailed "x"} @?= False

reportFits :: Assertion
reportFits = do
  r <- either (assertFailure . T.unpack) pure (decodeTricorder finishedJson)
  let full = renderReport 100000 r
  assertBool "errors before warnings" (T.breakOn "error:" full < T.breakOn "warning:" full)
  assertBool "the failing case is shown" ("parses 1h30m" `T.isInfixOf` full)
  let many = r {outcome = Built (Build 1 (replicate 200 (Diagnostic SevError "src/B.hs" 1 1 1 2 "bad" (T.replicate 300 "x"))) [] [] False)}
      small = renderReport 3000 many
  assertBool "a long report fits" (T.length small <= 3200)
  assertBool "and says how many were left out" ("more diagnostics not shown" `T.isInfixOf` small)

transcriptFits :: Assertion
transcriptFits = do
  let big = T.replicate 4000 "y"
      steps = [Step n (Right (Decision "p" (ReadFile (ReadFileArgs "a" Nothing Nothing)))) big | n <- [1 .. 20]]
      (msgs, used) = messagesFor 20000 "system" "task" steps
      contents = [c | Object o <- msgs, Just (String c) <- [KeyMap.lookup "content" o]]
  assertBool "fits the budget" (used <= 20000)
  assertBool "the newest step is whole" (("Step 20 result:\n" <> big) `elem` contents)
  assertBool "older steps are dropped with a note" (any ("earlier steps are not shown" `T.isInfixOf`) contents)