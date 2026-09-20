-- | One request, and the job loop built on it: plan, create or resume,
-- run the unfinished parts, assemble.
module Run
  ( Outcome (..)
  , send
  , problem
  , samplingFor
  , runJob
  , RunOpts (..)
  , Common (..)
  ) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock.POSIX (getPOSIXTime)
import Menu
import OpenSlop.Catalogue
import OpenSlop.Chunk (Part (..), chunk)
import OpenSlop.Engine
import OpenSlop.Http
import OpenSlop.Job
import OpenSlop.Stats (Stats (..), Verdict (..), judge)
import System.Directory (doesFileExist, listDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.Exit
import System.FilePath ((</>))
import System.IO
import System.Process.Typed
import System.Timeout (timeout)
import Text.Printf (printf)

data RunOpts = RunOpts
  { model :: Maybe Text
  , input :: Maybe Text
  -- ^ clip, -, or a path
  , prompt :: Maybe Text
  , promptFile :: Maybe FilePath
  , out :: Maybe FilePath
  , chunkOverride :: Maybe Int
  , resume :: Maybe Text
  , dryRun :: Bool
  , fresh :: Bool
  }

data Common = Common
  { catalogueFile :: FilePath
  , stateRoot :: FilePath
  , keyFile :: Maybe FilePath
  , timeoutSeconds :: Int
  }

data Outcome = Outcome
  { summary :: Summary
  , raw :: ByteString
  , failure :: Maybe HttpFailure
  , wallSeconds :: Int
  }

-- | Send one request under a ceiling. Streamed text is echoed to stderr as
-- it arrives when asked; the raw lines are kept for the failed/ directory.
send :: Client -> Auth -> Int -> Entry -> Request -> Bool -> IO Outcome
send client auth limitSeconds e req echo = do
  rawRef <- newIORef []
  repliesRef <- newIORef []
  t0 <- nowSeconds
  r' <- timeout (limitSeconds * 1000000) $ postLines client auth e.endpoint.url (requestPath req) req \line -> do
    modifyIORef' rawRef (line :)
    forM_ (parseReply e.engine line) \rep -> do
      modifyIORef' repliesRef (rep :)
      when echo case rep of
        Token t -> TIO.hPutStr stderr t >> hFlush stderr
        Final t _ -> TIO.hPutStr stderr t >> hFlush stderr
        ServerError _ -> pure ()
  t1 <- nowSeconds
  raws <- readIORef rawRef
  replies <- readIORef repliesRef
  let r = fromMaybe (Left (Transport ("no complete answer within " <> tshow limitSeconds <> " seconds (--timeout)"))) r'
  pure
    Outcome
      { summary = summarise (reverse replies)
      , raw = BC.unlines (reverse raws)
      , failure = either Just (const Nothing) r
      , wallSeconds = t1 - t0
      }

nowSeconds :: IO Int
nowSeconds = floor <$> getPOSIXTime

-- | Why an outcome is not a usable response, or Nothing when it is.
problem :: Entry -> Outcome -> Maybe Text
problem e o
  | Just err <- o.summary.errorText = Just ("the server said: " <> err)
  | Just f <- o.failure = Just (describeFailure f)
  | B.null o.raw = Just "the server sent nothing"
  -- Nothing parsed at all: hailo-ollama answers an oversized prompt with a
  -- 500 whose body is plain text, and a proxy may answer with HTML.
  | Nothing <- o.summary.final, T.null o.summary.output =
      Just ("the response is not JSON: " <> T.take 300 (TE.decodeUtf8With TE.lenientDecode o.raw))
  | Nothing <- o.summary.final, e.streams = Just "the stream ended without its final line, so the part hit the timeout or the server went away"
  | Nothing <- o.summary.final = Just "the response has no final line"
  | T.null (T.strip o.summary.output) = Just "the model returned no text"
  | otherwise = Nothing

samplingFor :: Budget -> Sampling
samplingFor b = Sampling {ctx = b.ctx, predict = b.predict, temperature = b.temperature, seed = Nothing}

-- | The named prompts shipped with the package, at $OPEN_SLOP_PROMPTS. The
-- home-manager module sets it to the prompts/ directory in the store.
promptsDir :: IO (Maybe FilePath)
promptsDir = lookupEnv "OPEN_SLOP_PROMPTS"

-- | @-P NAME@ with no slash and no .md is a prompt from the shipped set;
-- anything else is a path.
resolvePrompt :: FilePath -> IO Text
resolvePrompt spec
  | '/' `elem` spec || ".md" `isSuffixOf'` spec = readOrDie spec
  | otherwise = do
      dir <- promptsDir
      case dir of
        Nothing -> die' ("-P " <> T.pack spec <> " names a shipped prompt, and OPEN_SLOP_PROMPTS is not set; pass a path")
        Just d -> do
          let path = d </> (spec <> ".md")
          ok <- doesFileExist path
          unless ok do
            available <- filter (\f -> ".md" `isSuffixOf'` f && f /= "README.md") <$> listDirectory d
            die' ("no prompt named " <> T.pack spec <> " in " <> T.pack d <> "; available: " <> T.intercalate ", " (map (T.pack . stripMd) available))
          readOrDie path
  where
    isSuffixOf' suf str = reverse suf == take (length suf) (reverse str)
    stripMd f = if ".md" `isSuffixOf'` f then take (length f - 3) f else f
    readOrDie p = do
      ok <- doesFileExist p
      unless ok (die' ("no such file: " <> T.pack p))
      TIO.readFile p

-- | The instruction used when none is given: prompts/reference-docs.md from
-- the shipped set, or a built-in copy when the set is not on this machine.
defaultInstruction :: IO Text
defaultInstruction = do
  dir <- promptsDir
  case dir of
    Just d -> do
      let path = d </> "reference-docs.md"
      ok <- doesFileExist path
      if ok then TIO.readFile path else pure builtIn
    Nothing -> pure builtIn
  where
    builtIn =
      T.unlines
        [ "You are writing reference documentation for the source text that follows."
        , "For each file in it, write a level-2 Markdown heading naming the file, then"
        , "say what the file is for, what it provides to the rest of the system, and"
        , "any behaviour a maintainer would not guess from names alone."
        , "State only what the text shows. Where the text is silent, say so. Do not"
        , "invent functions, options, or behaviour."
        , "Write plain declarative sentences. Do not use em-dashes."
        , "The text may be one part of a larger input. Document only what is in this"
        , "part."
        ]

-- | The clipboard, a pipe, or a file. Never a terminal paste: a tty in
-- canonical mode discards everything past 4095 bytes of a line.
readInput :: Text -> IO Text
readInput = \case
  "clip" -> do
    display <- lookupEnv "DISPLAY"
    when (maybe True null display) (die' "no X display, so no clipboard. Use -i FILE, or pipe the text in.")
    (code, o, _) <- readProcess (proc "xsel" ["--clipboard", "--output"])
    unless (code == ExitSuccess) (die' "xsel failed")
    pure (decode (BL.toStrict o))
  "-" -> do
    tty <- hIsTerminalDevice stdin
    when tty (die' "refusing to read a paste from the terminal, which cuts lines at 4095 bytes. Use -i clip, -i FILE, or a pipe.")
    decode <$> B.hGetContents stdin
  path -> do
    ok <- doesFileExist (T.unpack path)
    unless ok (die' ("no such file: " <> path))
    decode <$> B.readFile (T.unpack path)
  where
    decode = TE.decodeUtf8With TE.lenientDecode

runJob :: Common -> Client -> Auth -> Catalogue -> RunOpts -> IO ()
runJob common client auth cat o = do
  when (isJust o.resume && (o.fresh || isJust o.input || isJust o.model || isJust o.prompt || isJust o.promptFile)) $
    die' "-r uses the job's stored input, model and instruction; drop -i, -m, -p, -P and --fresh"
  when (isJust o.prompt && isJust o.promptFile) (die' "-p and -P are exclusive")
  forM_ o.chunkOverride \c -> when (c < 1024) (die' "--chunk-bytes below 1024 leaves nothing worth sending")

  -- Input first, so a bad input fails before any server is contacted.
  input <- case o.resume of
    Just _ -> pure Nothing
    Nothing -> do
      tty <- hIsTerminalDevice stdin
      let src = fromMaybe (if tty then "clip" else "-") o.input
      t <- readInput src
      when (T.null (T.strip t)) (die' ("the input (" <> src <> ") is empty"))
      say ("input: " <> tshow (B.length (TE.encodeUtf8 t)) <> " bytes from " <> src)
      pure (Just (src, t))

  p <- probe client auth cat
  when (null p.entries) do
    mapM_ (say . ("unavailable  " <>)) p.unavailable
    die' "no server reported any model"

  (entry, budget, instruction, job) <- case (o.resume, input) of
    (Just jid, _) -> do
      opened <- try @SomeException (open common.stateRoot (JobId jid))
      job <- either (\ex -> die' ("no job " <> jid <> " under " <> T.pack common.stateRoot <> " (" <> T.pack (displayException ex) <> ")")) pure opened
      e <- either die' pure (resolve p job.meta.model)
      -- The chunks on disk were cut for the stored budget. Today's catalogue
      -- does not get a say in a job that already exists.
      pure (e, job.meta.budget, job.instruction, job)
    (Nothing, Just (src, text)) -> do
      e <- chooseEntry p o.model
      TIO.hPutStrLn stderr (preview e)
      let budget = maybe e.budget (\c -> e.budget {chunkBytes = c}) o.chunkOverride
      instruction <- case (o.prompt, o.promptFile) of
        (Just t, _) -> pure t
        (_, Just f) -> resolvePrompt f
        _
          | o.dryRun -> defaultInstruction
          | otherwise -> do
              tty <- hIsTerminalDevice stdin
              if not tty
                then defaultInstruction
                else do
                  TIO.hPutStr stderr "llmq: instruction, or enter for the default reference-docs one:\n> "
                  hFlush stderr
                  l <- TIO.getLine
                  if T.null (T.strip l) then defaultInstruction else pure l
      when o.dryRun do
        planParts e budget text
        exitSuccess
      when o.fresh do
        let JobId jid = jobId e.entryId budget instruction text
        say ("discarding any existing job " <> jid)
        removePathForcibly (common.stateRoot </> T.unpack jid)
      (job, existed) <- create common.stateRoot e.entryId src budget instruction text
      let JobId jid = job.meta.id
      say (if existed then "job " <> jid <> " already exists; resuming it" else "job " <> jid <> " created in " <> T.pack job.dir)
      pure (e, budget, instruction, job)
    (Nothing, Nothing) -> die' "no input"

  let JobId jid = job.meta.id
  result <- withJobLock job (runParts client auth common.timeoutSeconds entry budget instruction job)
  case result of
    Nothing -> die' ("job " <> jid <> " is already running in another llmq")
    Just () -> pure ()

  outPath <- assemble job
  forM_ o.out \dest -> do
    TIO.readFile outPath >>= TIO.writeFile dest
    say ("copied to " <> T.pack dest)
  warnings <- fmap concat $ forM job.manifest \m -> do
    st <- partState job m.index
    pure case st of
      Done s | not (null s.warnings) -> ["part " <> tshow m.index <> ": " <> T.intercalate "; " s.warnings]
      _ -> []
  putStrLn outPath
  if null warnings
    then say "finished"
    else do
      say "finished WITH WARNINGS. Read these parts before trusting them:"
      mapM_ (TIO.hPutStrLn stderr . ("  " <>)) warnings
      exitWith (ExitFailure 2)

planParts :: Entry -> Budget -> Text -> IO ()
planParts e budget text = do
  let parts = chunk budget.chunkBytes text
      n = length parts
      total = sum (map (.bytes) parts)
      largest = maximum (0 : map (.bytes) parts)
      mid = length (filter (isJust . (.continues)) parts)
      largestTokens = floor (fromIntegral largest / budget.bytesPerToken) :: Int
  say (tshow n <> " parts, " <> tshow total <> " bytes, largest " <> tshow largest <> " of a " <> tshow budget.chunkBytes <> "-byte budget")
  say ("about " <> tshow largestTokens <> " tokens in the largest part at " <> tshow budget.bytesPerToken <> " bytes/token, in a " <> tshow budget.ctx <> "-token window")
  say (tshow mid <> " parts begin partway through a file")
  case e.tokPerSec of
    Just r ->
      say
        ( T.pack
            ( printf
                "output alone, if every part used its %d-token cap at the measured %.1f tok/s: %.1f hours, prefill not included"
                budget.predict
                r
                (fromIntegral (n * budget.predict) / r / 3600 :: Double)
            )
        )
    Nothing -> say "no measured rate for this model, so no time estimate"

runParts :: Client -> Auth -> Int -> Entry -> Budget -> Text -> Job -> IO ()
runParts client auth limitSeconds e budget instruction job = do
  let total = job.meta.parts
      JobId jid = job.meta.id
  states <- forM job.manifest \m -> (m,) <$> partState job m.index
  let todo = [m | (m, Pending) <- states]
  say (tshow (total - length todo) <> " of " <> tshow total <> " parts already done, " <> tshow (length todo) <> " to go")
  remainingRef <- newIORef (sum (map (.bytes) todo))
  doneBytesRef <- newIORef (0 :: Int)
  t0 <- nowSeconds
  forM_ todo \m -> do
    body <- TIO.readFile (job.dir </> "chunks" </> (printf "%04d" m.index <> ".txt"))
    let header =
          T.unwords
            ( ["Part " <> tshow m.index <> " of " <> tshow total <> "."]
                <> ["It begins partway through " <> c <> ", which starts in an earlier part." | Just c <- [m.continues]]
                <> ["Files that begin in this part: " <> T.intercalate ", " m.starts <> "." | not (null m.starts)]
            )
        req = buildRequest e.engine e.name (Prompt instruction header body) (samplingFor budget) e.streams
        reqBytes = BL.toStrict (encode req)
        failPart raw why retryable = do
          recordFailure job m.index raw reqBytes
          say ("part " <> tshow m.index <> " FAILED: " <> why)
          say ("raw response and request body kept in " <> T.pack (job.dir </> "failed"))
          say
            ( if retryable
                then "continue with: llmq -r " <> jid
                else "resuming job " <> jid <> " will fail the same way; its parts are fixed at " <> tshow budget.chunkBytes <> " bytes"
            )
          exitFailure
    say ("part " <> tshow m.index <> "/" <> tshow total <> ": " <> tshow m.bytes <> " bytes to " <> e.entryId)
    unless e.streams (say (engineName e.engine <> " does not stream; waiting for the whole answer"))
    out <- send client auth limitSeconds e req True
    TIO.hPutStrLn stderr ""
    case (problem e out, out.summary.final) of
      (Just why, _) -> failPart out.raw why True
      (Nothing, Nothing) -> failPart out.raw "the response has no final line" True
      (Nothing, Just info) -> case judge budget m.index m.bytes out.wallSeconds info of
        Truncated why -> failPart out.raw (why <> ". Start a new job with a smaller --chunk-bytes.") False
        Kept st -> do
          writePart job m.index out.summary.output st
          modifyIORef' remainingRef (subtract m.bytes)
          modifyIORef' doneBytesRef (+ m.bytes)
          say
            ( "part " <> tshow m.index <> " done in " <> tshow st.wallSeconds <> "s: "
                <> maybe "?" tshow st.promptTokens <> " prompt tokens at " <> maybe "?" tshow st.prefillTokPerSec <> " tok/s, "
                <> maybe "?" tshow st.outputTokens <> " output tokens at " <> maybe "?" tshow st.genTokPerSec <> " tok/s, "
                <> maybe "?" tshow st.bytesPerToken <> " bytes/token"
            )
          forM_ st.warnings \w -> say ("WARNING " <> w)
          remaining <- readIORef remainingRef
          doneBytes <- readIORef doneBytesRef
          now <- nowSeconds
          when (remaining > 0 && doneBytes > 0) do
            let eta = (now - t0) * remaining `div` doneBytes
            say (T.pack (printf "about %dh%02dm left at this session's rate, which is rough" (eta `div` 3600) (eta `mod` 3600 `div` 60)))