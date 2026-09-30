-- | What llmq-bench may do to the inference machine itself, over ssh.
--
-- Part of llmq-bench; Main's header says what is measured and why.
--
-- ============================================================================
-- WHY IT NEEDS TO
-- ============================================================================
--
-- Three measurements cannot be taken from the network alone:
--
--   llama-server's own numbers need it running, and every other backend's
--   need it stopped, because it holds 5.5 GB on oracle. An unattended night
--   has to switch it between the two.
--
--   A load from the SD card needs the model's file out of the page cache.
--   Otherwise every load after the first reads the file from RAM, which is
--   a different and much smaller number.
--
--   llama-server's load time is its start time, measured by restarting it.
--
-- `--control USER@HOST` enables all three. Each is one fixed command run
-- through `sudo -n`, so it fails at once rather than waiting for a password
-- nobody will type, and the row's sudoers rules allow exactly these
-- commands and nothing wider (llama-server.nix's controlledBy for the
-- first and third, a rule in the row's host configuration for the second).
-- ssh runs with BatchMode, so a missing key fails the same way.
module Control
  ( Control (..)
  , remote
  , llamaServer
  , dropCaches
  , isActive
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

newtype Control = Control {target :: Text}

-- | Run one command on the row. Left carries what went wrong.
remote :: Control -> [Text] -> IO (Either Text Text)
remote c args = do
  (code, out, err) <-
    readProcessWithExitCode
      "ssh"
      (["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", T.unpack c.target, "--"] <> map T.unpack args)
      ""
  pure case code of
    ExitSuccess -> Right (T.strip (T.pack out))
    ExitFailure k -> Left ("ssh " <> c.target <> " " <> T.unwords args <> " exited " <> T.pack (show k) <> ": " <> T.strip (T.pack err))

-- | start, stop or restart llama-server.service.
llamaServer :: Control -> Text -> IO (Either Text ())
llamaServer c verb = fmap (const ()) <$> remote c ["sudo", "-n", "/run/current-system/sw/bin/systemctl", verb, "llama-server.service"]

isActive :: Control -> Text -> IO Bool
isActive c unit = either (const False) (== "active") <$> remote c ["systemctl", "is-active", unit]

-- | Drop clean pages from the page cache, so the next read of a model file
-- comes from the SD card.
dropCaches :: Control -> IO (Either Text ())
dropCaches c = fmap (const ()) <$> remote c ["sudo", "-n", "/run/current-system/sw/bin/sysctl", "-w", "vm.drop_caches=3"]
