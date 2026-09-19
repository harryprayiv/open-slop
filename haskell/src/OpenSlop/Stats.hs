-- | What a finished part is reduced to, and what it means.
--
-- Two verdicts. 'Truncated' fails the part: the prompt filled the window,
-- and ollama drops the FRONT of an oversized prompt, where the instruction
-- is, then answers 200. Warnings keep the part and mark the job.
module OpenSlop.Stats
  ( Stats (..)
  , Verdict (..)
  , judge
  , rate
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import OpenSlop.Catalogue (Budget (..))
import OpenSlop.Engine (FinalInfo (..))

data Stats = Stats
  { part :: Int
  , bytes :: Int
  , wallSeconds :: Int
  , promptTokens :: Maybe Int
  , outputTokens :: Maybe Int
  , prefillTokPerSec :: Maybe Double
  , genTokPerSec :: Maybe Double
  , loadSeconds :: Maybe Double
  , bytesPerToken :: Maybe Double
  , hitLimit :: Bool
  , serverTruncated :: Bool
  , warnings :: [Text]
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data Verdict
  = Truncated Text
  -- ^ fail the part; resuming with the same chunk fails again
  | Kept Stats
  deriving stock (Show)

rate :: Maybe Int -> Maybe Double -> Maybe Double
rate (Just n) (Just ns) | ns > 0 = Just (roundTo 1 (fromIntegral n / (ns / 1e9)))
rate _ _ = Nothing

roundTo :: Int -> Double -> Double
roundTo places x = fromIntegral (round (x * f) :: Integer) / f
  where
    f = 10 ^^ places

judge :: Budget -> Int -> Int -> Int -> FinalInfo -> Verdict
judge budget partIx bytes wall info
  | info.serverTruncated =
      Truncated "the server reported truncating the prompt to fit its context"
  | Just p <- info.promptTokens, p >= budget.ctx - 16 =
      Truncated
        ( "the prompt filled the "
            <> tshow budget.ctx
            <> "-token window, so the server cut its front, instruction included"
        )
  | otherwise = Kept stats
  where
    bpt = case info.promptTokens of
      Just p | p > 0 -> Just (roundTo 2 (fromIntegral bytes / fromIntegral p))
      _ -> Nothing
    stats =
      Stats
        { part = partIx
        , bytes
        , wallSeconds = wall
        , promptTokens = info.promptTokens
        , outputTokens = info.outputTokens
        , prefillTokPerSec = rate info.promptTokens info.promptNs
        , genTokPerSec = rate info.outputTokens info.outputNs
        , loadSeconds = fmap (\ns -> roundTo 1 (ns / 1e9)) info.loadNs
        , bytesPerToken = bpt
        , hitLimit = info.hitLimit
        , serverTruncated = info.serverTruncated
        , warnings =
            concat
              [ ["output hit the " <> tshow budget.predict <> "-token cap and stops mid-thought" | info.hitLimit]
              , [ "the prompt took " <> tshow p <> " tokens, past the " <> tshow (budget.ctx - budget.predict) <> " left after the output reservation"
                | Just p <- [info.promptTokens]
                , p > budget.ctx - budget.predict
                ]
              , [ "prompt plus output passed the " <> tshow budget.ctx <> "-token window, so the end of the output was written without the start of the input"
                | Just p <- [info.promptTokens]
                , Just o <- [info.outputTokens]
                , p + o > budget.ctx
                ]
              , [ "observed " <> tshow b <> " bytes/token against the catalogue's " <> tshow budget.bytesPerToken <> "; a later part may overflow"
                | Just b <- [bpt]
                , bytes * 2 >= budget.chunkBytes
                , b < budget.bytesPerToken * 0.9
                ]
              ]
        }

tshow :: (Show a) => a -> Text
tshow = T.pack . show
