-- | llmq-claims: one call per subject, evidence-checked claims out.
--
-- ============================================================================
-- WHAT THE MEASUREMENTS OF 2026-09-26 DECIDED ABOUT THIS SHAPE
-- ============================================================================
--
--   * A server reuses the KV cache of a shared prefix, and the reuse is
--     nearly total: a 4,688-token bundle with a different question on the
--     end came back with 4,675 tokens cached and 4.9 s of prefill, against
--     about 220 s cold. So the bundle goes in front of every request and is
--     paid for once.
--   * That cold cost is what every long failure here has been. A warm-up
--     request now runs before the loop and reports what it cost, and the
--     default timeout is ten minutes rather than an hour, so a stall shows
--     up while you are still watching.
--   * minItems in the schema makes coverage a property of the grammar.
--   * Constrained decoding costs nothing against free text.
--   * maxLength costs nothing either: warm, the same request with no bound,
--     a 60-character bound and a 220-character bound all took 25 s and
--     returned the same answer.
--   * Decode is the whole cost, about 0.7 tok/s at 8K of context, so the
--     token cap is also the wall clock and the design goal is fewer output
--     tokens rather than fewer input tokens.
--
-- ============================================================================
-- A TRUNCATED ANSWER IS A FAILURE, NOT AN EMPTY RESULT
-- ============================================================================
--
-- Under a grammar, an answer that stops at the token cap is incomplete JSON
-- by construction: the decoder was inside a string when the budget ran out.
-- That is reported with the finish reason and the start of what arrived,
-- because an earlier version logged "0 claims" and left no way to tell a
-- truncation from a refusal.
module Main (main) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import OpenSlop.Catalogue (Engine (..))
import OpenSlop.Chunk (fileMarker)
import OpenSlop.Claim
import OpenSlop.Gateway.Translate (Reply (..), parseBackendReply)
import OpenSlop.Http
import OpenSlop.OpenAI (FinishReason (..))
import Options.Applicative
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit
import System.FilePath ((</>))
import System.IO
import Text.Printf (printf)

data Opts = Opts
  { endpoint :: Text
  , model :: Maybe Text
  , keyFile :: Maybe FilePath
  , input :: FilePath
  , outDir :: FilePath
  , minClaims :: Int
  , maxClaims :: Int
  , maxTokens :: Int
  , instructionFile :: Maybe FilePath
  , timeoutSeconds :: Int
  , only :: Maybe Text
  , dryRun :: Bool
  }

optsP :: Parser Opts
optsP =
  Opts
    <$> strOption (long "endpoint" <> short 'e' <> metavar "URL" <> help "llama-server or gateway base URL, e.g. http://192.168.8.173:8081")
    <*> optional (strOption (long "model" <> short 'm' <> metavar "ID" <> help "model id, for a gateway that routes by name"))
    <*> optional (strOption (long "key-file" <> metavar "FILE" <> help "bearer key, when the endpoint is the gateway"))
    <*> strOption (long "input" <> short 'i' <> metavar "FILE" <> help "a catsrc dump: files separated by Start of / End of markers")
    <*> strOption (long "out" <> short 'o' <> metavar "DIR" <> value "claims-out" <> showDefault)
    <*> option auto (long "min-claims" <> metavar "N" <> value 2 <> showDefault <> help "the schema's minItems: the model cannot return fewer")
    <*> option auto (long "max-claims" <> metavar "N" <> value 3 <> showDefault)
    <*> option auto (long "max-tokens" <> metavar "N" <> value 500 <> showDefault <> help "output cap per subject; at 0.7 tok/s this is also the per-subject time, so 500 is about twelve minutes")
    <*> optional (strOption (long "instruction" <> metavar "FILE"))
    <*> option auto (long "timeout" <> short 't' <> metavar "SECS" <> value 600 <> showDefault <> help "per request; a cold prefix cache costs about 220 s on a 5K bundle, so a stall past ten minutes is a stall")
    <*> optional (strOption (long "only" <> metavar "SUBSTR" <> help "run only subjects whose name contains this"))
    <*> switch (long "dry-run" <> short 'n' <> help "list the subjects and the schema, send nothing")

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  o <- execParser (info (optsP <**> helper) (fullDesc <> progDesc "evidence-checked claims, one request per subject, over a shared prefix"))

  ok <- doesFileExist o.input
  unless ok (die' ("no such file: " <> T.pack o.input))
  bundle <- TE.decodeUtf8With TE.lenientDecode <$> B.readFile o.input
  let subjects0 = splitSubjects bundle
      subjects = case o.only of
        Nothing -> subjects0
        Just s -> [x | x <- subjects0, s `T.isInfixOf` x.name]
  when (null subjects) (die' "no `Start of` markers in the input, so there are no subjects")
  say (tshow (length subjects) <> " subjects, " <> tshow (B.length (TE.encodeUtf8 bundle)) <> " bytes of bundle")
  forM_ subjects \s -> say ("  " <> s.name <> " (" <> tshow (T.length s.source) <> " chars)")

  instruction <- maybe (pure defaultInstruction) TIO.readFile o.instructionFile

  when o.dryRun do
    TIO.putStrLn (TE.decodeUtf8With TE.lenientDecode (BL.toStrict (Aeson.encode (claimSchema [s.name | s <- subjects] (o.minClaims, o.maxClaims)))))
    exitSuccess

  auth <- case o.keyFile of
    Nothing -> pure NoAuth
    Just f -> Bearer . T.strip <$> TIO.readFile f
  client <- newClient
  createDirectoryIfMissing True o.outDir

  -- Warm the server's prefix cache, and say what it cost. Every long
  -- failure this project has had was that cost hiding inside a request that
  -- looked hung.
  do
    t0 <- now
    let probe =
          object
            ( [ "messages" .= [object ["role" .= ("user" :: Text), "content" .= (bundle <> "\n\n" <> instruction <> "\n\nReply with the word ok.")]]
              , "max_tokens" .= (4 :: Int)
              , "temperature" .= (0 :: Int)
              , "stream" .= False
              , "cache_prompt" .= True
              ]
                <> maybe [] (\m -> ["model" .= m]) o.model
            )
    w <- postJsonWithin (Just o.timeoutSeconds) client auth o.endpoint "/v1/chat/completions" probe
    t1 <- now
    case w of
      Left f -> die' ("the endpoint did not answer a warm-up request within " <> tshow o.timeoutSeconds <> "s: " <> describeFailure f)
      Right raw ->
        say
          ( "prefix warmed in " <> tshow (t1 - t0) <> "s: " <> tshow (cachedTokens raw) <> " of "
              <> tshow (promptTokensOf raw) <> " prompt tokens were already cached"
          )

  results <- forM (zip [1 :: Int ..] subjects) \(i, s) -> do
    say ("subject " <> tshow i <> "/" <> tshow (length subjects) <> ": " <> s.name)
    t0 <- now
    let body = request o bundle instruction subjects s
    r <- postJsonWithin (Just o.timeoutSeconds) client auth o.endpoint "/v1/chat/completions" body
    t1 <- now
    case r >>= \raw -> (,) raw <$> either (Left . Transport) Right (parseBackendReply LlamaServer raw) of
      Left f -> do
        say ("  FAILED after " <> tshow (t1 - t0) <> "s: " <> describeFailure f)
        pure (s, Verdict [] [], t1 - t0, 0)
      Right (raw, reply) -> do
        let outTok = fromMaybe 0 reply.completionTokens
            cached = cachedTokens raw
            finished = case reply.finish of
              FinishStop -> "stop"
              FinishLength -> "length"
        case parseClaims reply.content of
          Left e -> do
            say ("  " <> tshow (t1 - t0) <> "s, " <> tshow outTok <> " output tokens, " <> tshow cached <> " cached, finish=" <> finished)
            say
              ( if reply.finish == FinishLength
                  then "  the answer hit the " <> tshow o.maxTokens <> "-token cap with the schema unfinished, so it is not valid JSON. Raise --max-tokens, or lower --max-claims."
                  else "  the answer did not parse: " <> T.pack e
              )
            say ("  first 200 characters: " <> T.take 200 reply.content)
            BL.writeFile (o.outDir </> T.unpack (slug s.name) <> ".raw.json") (BL.fromStrict (TE.encodeUtf8 reply.content))
            pure (s, Verdict [] [], t1 - t0, outTok)
          Right raws -> do
            let v = verify subjects raws
            say
              ( "  " <> tshow (t1 - t0) <> "s, " <> tshow outTok <> " output tokens, " <> tshow cached <> " cached, finish=" <> finished <> ", "
                  <> tshow (length raws) <> " claims, " <> tshow (length v.accepted) <> " accepted, "
                  <> tshow (length v.rejected) <> " rejected"
              )
            forM_ v.rejected \(_, why) -> say ("  rejected: " <> why)
            BL.writeFile (o.outDir </> T.unpack (slug s.name) <> ".json") (encode v)
            pure (s, v, t1 - t0, outTok)

  let allAccepted = concat [v.accepted | (_, v, _, _) <- results]
      allRejected = concat [v.rejected | (_, v, _, _) <- results]
      wall = sum [w | (_, _, w, _) <- results]
      toks = sum [t | (_, _, _, t) <- results]
  TIO.writeFile (o.outDir </> "claims.md") (renderClaims subjects allAccepted)
  say
    ( T.pack
        ( printf
            "%d accepted, %d rejected, %d output tokens, %ds wall, %.2f tok/s"
            (length allAccepted)
            (length allRejected)
            toks
            wall
            (fromIntegral toks / fromIntegral (max 1 wall) :: Double)
        )
    )
  putStrLn (o.outDir </> "claims.md")
  when (null allAccepted) (exitWith (ExitFailure 2))

-- | One request. The bundle and the instruction are byte-identical across
-- subjects and come FIRST, so the server's prefix cache covers everything
-- but the last line.
request :: Opts -> Text -> Text -> [Subject] -> Subject -> Value
request o bundle instruction subjects s =
  object
    ( [ "messages"
          .= [ object
                 [ "role" .= ("user" :: Text)
                 , "content" .= (bundle <> "\n\n" <> instruction <> "\n\nSubject for this request: " <> s.name)
                 ]
             ]
      , "max_tokens" .= o.maxTokens
      , "temperature" .= (0 :: Int)
      , "seed" .= (1 :: Int)
      , "stream" .= False
      , "cache_prompt" .= True
      , "response_format"
          .= object
            [ "type" .= ("json_schema" :: Text)
            , "json_schema"
                .= object
                  [ "name" .= ("claims" :: Text)
                  , "strict" .= True
                  , "schema" .= claimSchema [x.name | x <- subjects] (o.minClaims, o.maxClaims)
                  ]
            ]
      ]
        <> maybe [] (\m -> ["model" .= m]) o.model
    )

-- | How much of the prompt the server did not have to re-evaluate.
-- llama-server reports it under usage.prompt_tokens_details.cached_tokens;
-- a number near the prompt size means the shared prefix held, and a small
-- one means something evicted it and this request paid the cold cost.
cachedTokens :: BL.ByteString -> Int
cachedTokens = fieldUnder ["usage", "prompt_tokens_details", "cached_tokens"]

promptTokensOf :: BL.ByteString -> Int
promptTokensOf = fieldUnder ["usage", "prompt_tokens"]

fieldUnder :: [Text] -> BL.ByteString -> Int
fieldUnder path raw = fromMaybe 0 (Aeson.decode raw >>= go path)
  where
    go [] (Aeson.Number n) = Just (truncate n)
    go (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= go ks
    go _ _ = Nothing

parseClaims :: Text -> Either String [RawClaim]
parseClaims t = do
  v <- eitherDecode (BL.fromStrict (TE.encodeUtf8 t))
  parseEither (withObject "claims" (.: "claims")) v

-- | Split a catsrc dump into one subject per file.
splitSubjects :: Text -> [Subject]
splitSubjects t = go Nothing [] (T.lines t)
  where
    go current acc [] = close current acc
    go current acc (l : ls) = case fileMarker "Start" (TE.encodeUtf8 l) of
      Just f -> close current acc <> go (Just (f, [])) [] ls
      Nothing -> case current of
        Nothing -> go Nothing acc ls
        Just (f, body) -> go (Just (f, l : body)) acc ls
    close Nothing _ = []
    close (Just (f, body)) _ = [Subject {name = f, source = T.unlines (reverse body)}]

-- | Every rule here was written against a measured rejection. The run of
-- 2026-09-26 produced sixteen claims of which six were the model's fault:
-- two quotes copied from a neighbouring file, one joining three lines into
-- one string, one dropping the closing brace of a Nix ''${ escape, and two
-- statements using words nowhere in the bundle. The second run added a
-- seventh: a quote that announced a message format instead of containing
-- it. The third run added an eighth failure, which is now the schema's job
-- rather than the instruction's: a sixty-word sentence that ran to the
-- token cap.
defaultInstruction :: Text
defaultInstruction =
  T.unlines
    [ "Above is the source text. For the subject named at the end of this message, and for no other subject, return claims about it."
    , ""
    , "Each claim has:"
    , "  subject:   exactly the subject named below."
    , "  kind:      purpose, interface, behaviour, reason, or openIssue."
    , "  quotes:    ONE fragment, at most fifteen words, copied CHARACTER FOR CHARACTER from that subject's own text. A quote that is not in that subject is rejected."
    , "  statement: ONE sentence, at most 220 characters. The schema enforces this, so say the specific thing rather than starting a general one."
    , ""
    , "Rules that decide whether a claim is kept:"
    , "  Quote only from the subject named below. Other files appear above; their lines are not evidence here."
    , "  The quote must CONTAIN what the statement is about. A line that announces something, ending in a colon, is not evidence for the lines after it."
    , "  Never join two lines into one quote. Pick a single line."
    , "  Never quote a line containing ''${ or a backslash escape. Choose a different line."
    , "  Never abbreviate a quote with an ellipsis."
    , "  A claim of kind reason must quote a COMMENT giving that reason. If no comment gives it, return no reason claim: a rationale you worked out yourself is not the file's reasoning."
    , "  Do not use a word unless it appears in the text. Names of systems, tools or concepts you know from elsewhere are rejected."
    , ""
    , "Emit compact JSON with no indentation and no newlines between fields. Whitespace costs output budget and this model produces about forty tokens per minute."
    , ""
    , "Prefer few precise claims to many vague ones. Prefer the least obvious thing in the file to the most obvious. Do not repeat a claim."
    ]

slug :: Text -> Text
slug = T.map (\c -> if c `elem` ("/ :" :: String) then '-' else c)

now :: IO Int
now = floor <$> getPOSIXTime

say :: Text -> IO ()
say t = TIO.hPutStrLn stderr ("llmq-claims: " <> t)

die' :: Text -> IO a
die' t = say t >> exitFailure

tshow :: (Show a) => a -> Text
tshow = T.pack . show