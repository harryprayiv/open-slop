-- | The agent's own checkout of the project.
--
-- Part of llmq-agent. The agent never writes to the user's working tree. It
-- gets a git worktree of the project at a revision (HEAD by default) on a
-- new branch, llmq-agent/<run>, and every edit it makes is committed there
-- as one commit per step. When the run ends the worktree is removed and the
-- branch stays, so the result is reviewed and taken like any other branch:
--
--   git diff HEAD...llmq-agent/<run>
--   git merge llmq-agent/<run>
--
-- Changes in the user's tree that are not committed are not in the
-- worktree; the run says so at the start when there are any.
module Git
  ( Checkout (..)
  , topLevel
  , dirtyFiles
  , addWorktree
  , removeWorktree
  , commitAll
  , diffStat
  , changed
  , deleteBranch
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import System.Exit (ExitCode (..))
import System.Process.Typed (proc, readProcess)

data Checkout = Checkout
  { repo :: FilePath
  -- ^ the user's repository top level
  , worktree :: FilePath
  , branch :: Text
  , base :: Text
  -- ^ the revision the branch starts from, as a commit id
  }

git :: FilePath -> [String] -> IO (Either Text Text)
git dir args = do
  r <- try @SomeException (readProcess (proc "git" (["-C", dir] <> args)))
  pure case r of
    Left e -> Left ("git: " <> T.pack (show e))
    Right (ExitSuccess, out, _) -> Right (lenient out)
    Right (ExitFailure _, _, err) -> Left ("git " <> T.unwords (map T.pack args) <> ": " <> T.strip (lenient err))
  where
    lenient = TE.decodeUtf8With TE.lenientDecode . BL.toStrict

topLevel :: FilePath -> IO (Either Text FilePath)
topLevel dir = fmap (T.unpack . T.strip) <$> git dir ["rev-parse", "--show-toplevel"]

dirtyFiles :: FilePath -> IO [Text]
dirtyFiles dir = either (const []) (filter (not . T.null) . T.lines) <$> git dir ["status", "--porcelain"]

addWorktree :: FilePath -> FilePath -> Text -> Text -> IO (Either Text Checkout)
addWorktree repo worktree branch rev =
  git repo ["rev-parse", "--verify", T.unpack rev <> "^{commit}"] >>= \case
    Left e -> pure (Left e)
    Right commit -> do
      let base = T.strip commit
      r <- git repo ["worktree", "add", "--quiet", "-b", T.unpack branch, worktree, T.unpack base]
      pure (Checkout {repo, worktree, branch, base} <$ r)

-- | Remove the worktree and keep the branch.
removeWorktree :: Checkout -> IO (Either Text ())
removeWorktree c = fmap (const ()) <$> git c.repo ["worktree", "remove", "--force", c.worktree]

-- | Commit everything in the worktree; Right False when nothing changed.
commitAll :: Checkout -> Text -> IO (Either Text Bool)
commitAll c message = do
  dirty <- dirtyFiles c.worktree
  if null dirty
    then pure (Right False)
    else do
      a <- git c.worktree ["add", "--all"]
      case a of
        Left e -> pure (Left e)
        Right _ -> fmap (const True) <$> git c.worktree ["commit", "--quiet", "--no-verify", "-m", T.unpack message]

diffStat :: Checkout -> IO Text
diffStat c = either id id <$> git c.repo ["diff", "--stat", T.unpack c.base, T.unpack c.branch]

-- | Whether the branch has moved past its base.
changed :: Checkout -> IO Bool
changed c = either (const True) (\h -> T.strip h /= c.base) <$> git c.repo ["rev-parse", "--verify", T.unpack c.branch]

-- | Remove a branch the run made no commits on.
deleteBranch :: Checkout -> IO ()
deleteBranch c = () <$ git c.repo ["branch", "--quiet", "-D", T.unpack c.branch]
