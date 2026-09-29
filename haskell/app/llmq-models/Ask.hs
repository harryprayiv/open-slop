-- | Asking the selected model a question through llmq, with an estimate
-- first, a live indicator until the first words, and a summary after.
--
-- Part of llmq-models; Main describes the program.
module Ask (askModel) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Models
import Style
import System.Exit (ExitCode (..))
import System.IO
import System.Process


askModel :: Row -> IO ()
askModel r = do
  leaveScreen
  let target = r.backend <> "/" <> r.model
  TIO.putStrLn ""
  TIO.putStr (fg (backendColour r.backend) "● " <> bold (fg cText target) <> fg cMuted "   empty line cancels\n" <> fg cAccent "❯ ")
  hFlush stdout
  q <- T.strip <$> TIO.getLine
  unless (T.null q) do
    TIO.putStrLn ("\n" <> fg cMuted (expectation r q) <> "\n")
    runAsk target q
    TIO.putStr (fg cMuted "\n  any key returns to the models")
    hFlush stdout
    hSetBuffering stdin NoBuffering
    hSetEcho stdin False
    _ <- getChar
    pure ()
  enterScreen

-- | What to expect, from this model's measurements. The prompt is the
-- question plus about 40 tokens of chat template.
expectation :: Row -> Text -> Text
expectation r q =
  case (r.prefill, r.decode) of
    (Just (_, pre), Just dec) ->
      let promptTokens = fromIntegral (T.length q) / r.charsPerToken + 40
          prompt = promptTokens / pre
          answer = 200 / dec
       in "expect the first words after "
            <> duration (prompt + 1)
            <> " if the model is in memory"
            <> maybe "" (\l -> ", or " <> duration (l + prompt + 1) <> " if it has to load") r.load
            <> "; then "
            <> fmt "%.1f" dec
            <> " tok/s, so 200 tokens take "
            <> duration answer
    _ -> "this model has no measurement, so there is no estimate"

-- | Run `llmq ask`, showing a spinner until the first output arrives, then
-- passing the output through as it comes.
runAsk :: Text -> Text -> IO ()
runAsk target q = do
  started <- getCurrentTime
  result <- try do
    (_, Just out, _, ph) <-
      createProcess
        (proc "llmq" ["ask", "-m", T.unpack target, T.unpack q])
          { std_out = CreatePipe
          , std_err = Inherit
          }
    hSetBuffering out NoBuffering
    firstOutput <- newEmptyMVar
    bytes <- newMVar (0 :: Int)
    _ <- forkIO (spinner started firstOutput)
    let pump seen = do
          chunk <- BS.hGetSome out 256
          unless (BS.null chunk) do
            unless seen do
              putMVar firstOutput ()
              threadDelay 50000
              TIO.putStr "\r\ESC[2K"
            BS.hPut stdout chunk
            hFlush stdout
            modifyMVar_ bytes (pure . (+ BS.length chunk))
            pump True
    pump False
    gotAny <- isJust <$> tryReadMVar firstOutput
    unless gotAny (putMVar firstOutput () >> threadDelay 50000 >> TIO.putStr "\r\ESC[2K")
    code <- waitForProcess ph
    finished <- getCurrentTime
    n <- readMVar bytes
    let secs = realToFrac (diffUTCTime finished started) :: Double
        tokens = fromIntegral n / 4 :: Double
    TIO.putStrLn ""
    TIO.putStrLn
      ( fg cMuted
          ( "done in " <> duration secs
              <> (if n > 0 then fmt ", about %.0f tokens" tokens <> fmt ", %.1f tok/s overall" (tokens / max 1 secs) else "")
              <> case code of
                ExitSuccess -> ""
                ExitFailure c -> ", llmq exited " <> T.pack (show c)
          )
      )
  case result of
    Left (e :: SomeException) -> TIO.putStrLn (fg cRed "\nllmq failed: " <> T.pack (show e))
    Right () -> pure ()

-- | A spinner with the seconds elapsed, on one line, until the first output.
spinner :: UTCTime -> MVar () -> IO ()
spinner started done = go (0 :: Int)
  where
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: String
    go i = do
      finished <- isJust <$> tryReadMVar done
      unless finished do
        now <- getCurrentTime
        let secs = round (realToFrac (diffUTCTime now started) :: Double) :: Int
        TIO.putStr ("\r\ESC[2K" <> fg cAccent (T.singleton (frames !! (i `mod` length frames))) <> fg cGrey (" thinking  " <> T.pack (show secs) <> " s"))
        hFlush stdout
        threadDelay 120000
        go (i + 1)
