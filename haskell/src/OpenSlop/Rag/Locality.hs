-- | Which servers may see private text.
--
-- Retrieved chunks are the user's files. They may be sent to a server on
-- this machine or the LAN and to nothing else. 'Lan' can only be built by
-- 'onLan', which reads the host out of the endpoint's URL and accepts it
-- only when it is loopback, a private address range, or a name that cannot
-- resolve outside the LAN. Every function in "OpenSlop.Rag" that sends text
-- takes a 'Lan', so a public endpoint is refused before any request exists.
--
-- Accepted hosts:
--
--   * localhost, 127.0.0.0/8, ::1
--   * 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16
--   * fc00::/7 (unique local), fe80::/10 (link local)
--   * a single-label name ("oracle"), or one ending in .lan, .local,
--     .internal or .home.arpa
--
-- A name is a claim about DNS, not a fact. Single-label and the listed
-- suffixes are accepted because a public resolver will not answer for them;
-- an address literal is the stronger form and is what the fleet's
-- endpoints use.
module OpenSlop.Rag.Locality
  ( Lan
  , lanEndpoint
  , lanUrl
  , onLan
  , hostOf
  , privateHost
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.Char (isDigit, isHexDigit, toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import OpenSlop.Catalogue (Endpoint (..), endpointId)
import Text.Read (readMaybe)

-- | An endpoint whose host was checked to be on the LAN. No constructor is
-- exported.
newtype Lan = Lan Endpoint

lanEndpoint :: Lan -> Endpoint
lanEndpoint (Lan e) = e

lanUrl :: Lan -> Text
lanUrl (Lan e) = e.url

onLan :: Endpoint -> Either Text Lan
onLan e = case hostOf e.url of
  Nothing -> Left (endpointId e <> ": cannot read a host out of " <> e.url)
  Just h
    | privateHost h -> Right (Lan e)
    | otherwise ->
        Left
          ( endpointId e
              <> ": "
              <> h
              <> " is not a loopback, private or LAN-only address; private text is never sent there"
          )

-- | The host part of an http(s) URL, without brackets, port or path.
hostOf :: Text -> Maybe Text
hostOf url = do
  rest <- T.stripPrefix "http://" url <|> T.stripPrefix "https://" url
  let authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') rest
      noUser = case T.breakOnEnd "@" authority of
        ("", a) -> a
        (_, a) -> a
  host <- case T.uncons noUser of
    Just ('[', v6) -> Just (T.takeWhile (/= ']') v6)
    _ -> Just (T.takeWhile (/= ':') noUser)
  if T.null host then Nothing else Just (T.toLower host)
  where
    a <|> b = maybe b Just a

privateHost :: Text -> Bool
privateHost h
  | h == "localhost" = True
  | Just w <- ipv4 h = privateV4 w
  | T.any (== ':') h = privateV6 h
  | not (T.any (== '.') h) = validLabel h
  | otherwise = any (`T.isSuffixOf` h) [".lan", ".local", ".internal", ".home.arpa"]
  where
    validLabel l = not (T.null l) && T.all (\c -> isDigit c || c == '-' || (c >= 'a' && c <= 'z')) l

ipv4 :: Text -> Maybe Word32
ipv4 t = case T.splitOn "." t of
  [a, b, c, d] -> do
    os <- traverse octet [a, b, c, d]
    pure (foldl (\acc o -> (acc `shiftL` 8) .|. fromIntegral o) 0 os)
  _ -> Nothing
  where
    octet s
      | T.null s || T.length s > 3 || not (T.all isDigit s) = Nothing
      | otherwise = do
          n <- readMaybe (T.unpack s) :: Maybe Int
          if n <= 255 then Just n else Nothing

privateV4 :: Word32 -> Bool
privateV4 w =
  inNet 0x7F000000 8
    || inNet 0x0A000000 8
    || inNet 0xAC100000 12
    || inNet 0xC0A80000 16
    || inNet 0xA9FE0000 16
  where
    inNet net bits = w .&. mask bits == net
    mask bits = complement32 ((1 `shiftL` (32 - bits)) - 1)
    complement32 x = maxBound - x

privateV6 :: Text -> Bool
privateV6 h
  | h == "::1" = True
  | otherwise = case T.splitOn ":" h of
      (first : _)
        | not (T.null first) && T.all isHexDigit first && T.length first <= 4 ->
            let v = hexValue first
             in (v .&. 0xFE00) == 0xFC00 || (v .&. 0xFFC0) == 0xFE80
      _ -> False
  where
    hexValue :: Text -> Int
    hexValue = T.foldl' (\acc c -> acc * 16 + hexDigit (toLower c)) 0
    hexDigit c
      | isDigit c = fromEnum c - fromEnum '0'
      | otherwise = fromEnum c - fromEnum 'a' + 10
