-- | Bearer keys: which client a request comes from.
--
-- The keys file has one client per line, `name key`, with blank lines and
-- lines starting with # ignored. It is rendered from sops on the gateway's
-- host and readable only by the gateway's user. Keys are held as their
-- sha256, and a presented key is looked up by its own sha256, so no
-- comparison runs over secret bytes and the key text is not kept in memory
-- past the load.
module OpenSlop.Gateway.Keys
  ( Keys
  , parseKeys
  , keyCount
  , authorise
  ) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

newtype Keys = Keys (Map ByteString Text)

keyCount :: Keys -> Int
keyCount (Keys m) = Map.size m

parseKeys :: Text -> Either Text Keys
parseKeys src = go Map.empty [] (zip [1 :: Int ..] (T.lines src))
  where
    go m _ [] =
      if Map.null m
        then Left "the keys file lists no clients; every request would be refused"
        else Right (Keys m)
    go m names ((n, l) : rest) =
      case T.words (T.strip l) of
        [] -> go m names rest
        (w : _) | "#" `T.isPrefixOf` w -> go m names rest
        [name, key]
          | T.length key < 24 -> Left ("line " <> tshow n <> ": the key for " <> name <> " is shorter than 24 characters")
          | name `elem` names -> Left ("line " <> tshow n <> ": client " <> name <> " is listed twice")
          | Map.member (h key) m -> Left ("line " <> tshow n <> ": " <> name <> " has the same key as another client")
          | otherwise -> go (Map.insert (h key) name m) (name : names) rest
        _ -> Left ("line " <> tshow n <> ": expected `name key`")
    h = SHA256.hash . TE.encodeUtf8
    tshow = T.pack . show

-- | The client for an Authorization header value, or why there is none.
authorise :: Keys -> Maybe ByteString -> Either Text Text
authorise (Keys m) = \case
  Nothing -> Left "no Authorization header; send Authorization: Bearer <key>"
  Just v -> case B.stripPrefix "Bearer " v of
    Nothing -> Left "Authorization is not a Bearer token"
    Just key -> maybe (Left "unknown key") Right (Map.lookup (SHA256.hash (B.dropWhile (== 32) key)) m)