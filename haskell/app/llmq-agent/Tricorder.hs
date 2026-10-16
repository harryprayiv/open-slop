-- | tricorder as the build oracle for Haskell.
--
-- Part of llmq-agent. tricorder (github.com/tweag/tricorder) keeps one
-- GHCi session per project loaded through `cabal repl --enable-multi-repl`,
-- rebuilds when a watched file changes, runs the test suites after a clean
-- build, and answers `tricorder status --json` with the state of the last
-- build. Nothing here builds anything itself: an edit is written to disk,
-- tricorder notices, and 'afterEdit' waits for the build that follows.
--
-- ============================================================================
-- KNOWING WHICH BUILD IS WHICH
-- ============================================================================
--
-- Right after a file is written, status may still show the build before
-- it, because the watcher has not fired yet. So 'afterEdit' takes the
-- identity of the report from before the edit (build id and completion
-- time) and waits for a settled report with a different one. An edit that
-- triggers no build (a file outside the watched directories) leaves the
-- identity unchanged; after `settleSeconds` of an unchanged, settled
-- report, that report is the answer.
--
-- The daemon stops itself after five idle minutes by default, which a slow
-- model can easily exceed between edits. "Stopped." from status starts it
-- again, and the wait continues with the build it does on starting.
--
-- tricorder must run where `cabal repl` works, so llmq-agent is started
-- from the project's development shell (`nix develop`).
module Tricorder
  ( TricorderConfig (..)
  , start
  , stop
  , current
  , afterEdit
  , lookupSource
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import OpenSlop.Agent.Oracle (Report, decodeTricorder, identity, settled)
import System.Exit (ExitCode (..))
import System.Process.Typed (proc, readProcess, setWorkingDir)
import System.Timeout (timeout)

data TricorderConfig = TricorderConfig
  { executable :: FilePath
  , root :: FilePath
  -- ^ where cabal.project or the .cabal file is
  , buildTimeout :: Int
  -- ^ seconds to wait for one build and its tests
  , settleSeconds :: Double
  }

run :: TricorderConfig -> [String] -> IO (Either Text Text)
run c args = do
  r <- try @SomeException (readProcess (setWorkingDir c.root (proc c.executable args)))
  pure case r of
    Left e -> Left (T.pack c.executable <> " " <> T.unwords (map T.pack args) <> ": " <> T.pack (show e))
    Right (code, out, err) -> case code of
      ExitSuccess -> Right (lenient out)
      ExitFailure n
        -- status exits non-zero after printing a failed build; the JSON is
        -- still on stdout
        | not (BL.null out) -> Right (lenient out)
        | otherwise -> Left (T.pack c.executable <> " exited " <> T.pack (show n) <> ": " <> T.strip (lenient err))
  where
    lenient = TE.decodeUtf8With TE.lenientDecode . BL.toStrict

start :: TricorderConfig -> IO (Either Text ())
start c = fmap (const ()) <$> run c ["start"]

stop :: TricorderConfig -> IO ()
stop c = () <$ run c ["stop"]

data Status = Stopped | Status Report

status :: TricorderConfig -> Bool -> IO (Either Text Status)
status c wait = do
  r <- run c (["status", "--json"] <> ["--wait" | wait])
  pure case r of
    Left e -> Left e
    Right out
      | T.strip out == "Stopped." -> Right Stopped
      | otherwise -> case decodeTricorder (lastJsonLine out) of
          Left e -> Left ("tricorder status gave something that is not a build state (" <> e <> "): " <> T.take 400 out)
          Right rep -> Right (Status rep)
  where
    lastJsonLine t = case filter ("{" `T.isPrefixOf`) (map T.strip (T.lines t)) of
      [] -> t
      ls -> last ls

-- | The settled state of the latest build, starting the daemon if needed.
current :: TricorderConfig -> IO (Either Text Report)
current c = waitFor c (\_ _ -> True)

-- | The build that follows an edit made after the given report.
afterEdit :: TricorderConfig -> Report -> IO (Either Text Report)
afterEdit c before = waitFor c (\rep elapsed -> identity rep /= identity before || elapsed >= c.settleSeconds)

waitFor :: TricorderConfig -> (Report -> Double -> Bool) -> IO (Either Text Report)
waitFor c done = do
  t0 <- getCurrentTime
  r <- timeout (c.buildTimeout * 1000000) (loop t0)
  pure (maybe (Left ("no settled build within " <> T.pack (show c.buildTimeout) <> " seconds")) id r)
  where
    loop t0 = do
      now <- getCurrentTime
      let elapsed = realToFrac (diffUTCTime now t0) :: Double
      status c False >>= \case
        Left e -> pure (Left e)
        Right Stopped -> do
          start c >>= \case
            Left e -> pure (Left ("tricorder would not start: " <> e))
            Right () -> threadDelay 500000 >> loop t0
        Right (Status rep)
          | settled rep && done rep elapsed -> pure (Right rep)
          | settled rep -> threadDelay 300000 >> loop t0
          | otherwise -> do
              -- blocks until the cycle in progress completes
              _ <- status c True
              threadDelay 200000
              loop t0

-- | `tricorder source QUERY`: a module's or a definition's source, from
-- the project or an installed package's documentation, offline.
lookupSource :: TricorderConfig -> Text -> IO Text
lookupSource c q
  | T.null (T.strip q) = pure "give a module name, or Module#name"
  | otherwise =
      run c ["source", T.unpack (T.strip q)] >>= \case
        Left e -> pure ("tricorder source failed: " <> e)
        Right out
          | T.null (T.strip out) -> pure ("tricorder source found nothing for " <> q)
          | otherwise -> pure out
