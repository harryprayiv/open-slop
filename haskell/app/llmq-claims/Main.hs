-- | llmq-claims: one call per subject, evidence-checked claims out.
--
-- The shape this project arrived at after measuring, on 2026-09-26, that:
--
--   * a server reuses the KV cache of a shared prefix (ollama 219 s cold
--     against 5.6 s warm; llama-server with cache_prompt 1.0 s warm, and
--     the cache survives across client processes), so sending the whole
--     part once and asking many small questions against it is affordable;
--   * minItems in the schema makes coverage a property of the grammar, so
--     a model cannot answer about one subject when asked about two;
--   * constrained decoding costs nothing against free text (1.03 against
--     1.005 tok/s), so there is no reason to generate prose;
--   * decode is the whole cost, 0.75 tok/s at 8K of context under a
--     grammar, so the design goal is fewer output tokens rather than fewer
--     input tokens. The token cap is also the wall clock: 450 tokens is
--     ten minutes.
--
-- Hence: the bundle goes in front of every request unchanged, each request
-- asks about one subject, and the answer is a short list of claims that
-- quote the source. Prose is rendered here from the accepted claims. The
-- model writes one sentence per claim and nothing else.
--
-- ============================================================================
-- A TRUNCATED ANSWER IS A FAILURE, NOT AN EMPTY RESULT
-- ============================================================================
--
-- Under a grammar, an answer that stops at the token cap is incomplete
-- JSON by construction: the decoder was inside a string when the budget
-- ran out. That is reported here with the finish reason and the start of
-- what did arrive, because the first version of this program logged "0
-- claims" and left no way to tell a truncation from a refusal.
module Main (main) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value, eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
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
    <*> option auto (long "max-claims" <> metavar "N" <> value 4 <> showDefault)
    <*> option auto (long "max-tokens" <> metavar "N" <> value 900 <> showDefault <> help "output cap per subject; at 0.75 tok/s this is also the per-subject time, so 900 is about twenty minutes")
    <*> optional (strOption (long "instruction" <> metavar "FILE"))
    <*> option auto (long "timeout" <> short 't' <> metavar "SECS" <> value 3600 <> showDefault)
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

  results <- forM (zip [1 :: Int ..] subjects) \(i, s) -> do
    say ("subject " <> tshow i <> "/" <> tshow (length subjects) <> ": " <> s.name)
    t0 <- now
    let body = request o bundle instruction subjects s
    r <- postJsonWithin (Just o.timeoutSeconds) client auth o.endpoint "/v1/chat/completions" body
    t1 <- now
    case r >>= (either (Left . Transport) Right . parseBackendReply LlamaServer) of
      Left f -> do
        say ("  FAILED after " <> tshow (t1 - t0) <> "s: " <> describeFailure f)
        pure (s, Verdict [] [], t1 - t0, 0)
      Right reply -> do
        let outTok = fromMaybe 0 reply.completionTokens
            finished = case reply.finish of
              FinishStop -> "stop"
              FinishLength -> "length"
        case parseClaims reply.content of
          Left e -> do
            -- Under a grammar this is almost always the token cap: the
            -- decoder was inside a string when the budget ran out, so the
            -- JSON cannot be complete. Saying so beats reporting no claims.
            say ("  " <> tshow (t1 - t0) <> "s, " <> tshow outTok <> " output tokens, finish=" <> finished)
            say
              ( if reply.finish == FinishLength
                  then "  the answer hit the " <> tshow o.maxTokens <> "-token cap with the schema unfinished, so it is not valid JSON. Raise --max-tokens, or lower --max-claims, or ask for shorter quotes."
                  else "  the answer did not parse: " <> T.pack e
              )
            say ("  first 200 characters: " <> T.take 200 reply.content)
            BL.writeFile (o.outDir </> T.unpack (slug s.name) <> ".raw.json") (BL.fromStrict (TE.encodeUtf8 reply.content))
            pure (s, Verdict [] [], t1 - t0, outTok)
          Right raws -> do
            let v = verify subjects raws
            say
              ( "  " <> tshow (t1 - t0) <> "s, " <> tshow outTok <> " output tokens, finish=" <> finished <> ", "
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

-- | Quotes are the expensive part of the budget, so the instruction caps
-- their length. Measured 2026-09-26: three claims with unbounded quotes
-- overran a 450-token cap before the array closed.
defaultInstruction :: Text
defaultInstruction =
  T.unlines
    [ "Above is the source text. For the subject named at the end of this message, and for no other subject, return claims about it."
    , ""
    , "Each claim has:"
    , "  subject:    exactly the subject named below."
    , "  kind:       purpose, interface, behaviour, reason, or openIssue."
    , "  quotes:     ONE fragment, at most fifteen words, copied CHARACTER FOR CHARACTER from that subject's text. A quote that is not in the text is rejected. Never abbreviate a quote with an ellipsis."
    , "  statement:  ONE sentence, at most thirty words, stating what the quote shows. Use only names that appear in the text."
    , "  confidence: stated when the text says it outright, inferred when you are reading between lines, unclear when you are unsure."
    , ""
    , "Prefer few precise claims to many vague ones. Do not describe the source in general terms. Do not repeat a claim. Do not mention anything that is not in the text."
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