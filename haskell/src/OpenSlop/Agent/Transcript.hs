-- | The conversation an agent has with its model, fitted to the model.
--
-- Every turn sends the instructions, the task, and the steps so far: each
-- step is the model's decision as an assistant message and what came of it
-- as a user message. A long run outgrows any window, so 'messagesFor'
-- keeps the newest steps whole and shortens older ones, then drops the
-- oldest. A shortened step keeps its plan, its action in a few words and
-- the first line of its observation, which is usually what the model needs
-- to remember: what it tried and whether it worked. It is written as
-- prose, not JSON, so it cannot be copied as a decision; the grammar only
-- admits decisions.
--
-- The budget is characters, from "OpenSlop.Capacity", so how much history
-- a model sees grows with its window.
module OpenSlop.Agent.Transcript
  ( Step (..)
  , messagesFor
  , observationRoom
  , briefAction
  ) where

import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TE
import OpenSlop.Agent.Action

data Step = Step
  { number :: Int
  , decision :: Either Text Decision
  -- ^ Left: a reply that did not decode, as it came
  , observation :: Text
  }
  deriving stock (Eq, Show)

-- | The most one observation may take: a third of the prompt, so a single
-- large file or error list cannot push every earlier step out.
observationRoom :: Int -> Int
observationRoom budget = max 2000 (budget `div` 3)

-- | Messages for the next turn, and the characters they take.
messagesFor :: Int -> Text -> Text -> [Step] -> ([Value], Int)
messagesFor budget system task steps = (msgs, used)
  where
    fixed = T.length system + T.length task + 64
    (kept, dropped) = choose (budget - fixed) (reverse steps)
    note
      | dropped == 0 = ""
      | otherwise = "\n\n[" <> tshow dropped <> " earlier steps are not shown, to fit the model's window]"
    msgs =
      [ role "system" system
      , role "user" (task <> note)
      ]
        <> concat [[role "assistant" a, role "user" o] | (a, o) <- reverse kept]
    used = fixed + T.length note + sum [T.length a + T.length o + 32 | (a, o) <- kept]
    role r c = object ["role" .= (r :: Text), "content" .= c]

-- | Newest first: whole while they fit, then shortened, then nothing.
choose :: Int -> [Step] -> ([(Text, Text)], Int)
choose room = go room True
  where
    go _ _ [] = ([], 0)
    go left whole (s : rest)
      | whole && size fullS <= left = add fullS (go (left - size fullS) True rest)
      | size shortS <= left = add shortS (go (left - size shortS) False rest)
      | otherwise = ([], 1 + length rest)
      where
        fullS = (reply s.decision, header s <> s.observation)
        shortS = (brief s.decision, header s <> firstLine s.observation <> " [shortened]")
    size (a, o) = T.length a + T.length o + 32
    add x (xs, n) = (x : xs, n)
    header s = "Step " <> tshow s.number <> " result:\n"
    firstLine t = T.take 300 (T.takeWhile (/= '\n') t)
    reply = \case
      Right d -> encodeText (toJSON d)
      Left raw -> T.take 600 raw
    brief = \case
      Right d -> "(shortened) " <> T.take 300 d.plan <> " Then: " <> briefAction d.step <> "."
      Left _ -> "(shortened) a reply that could not be read"

-- | An action in a few words, for logs and shortened steps.
briefAction :: Action -> Text
briefAction = \case
  BrowseDirectory x -> "BrowseDirectory " <> quoted x.directory
  ReadFile x ->
    "ReadFile "
      <> x.path
      <> maybe "" (\a -> " from line " <> tshow a) x.startLine
      <> maybe "" (\b -> " to line " <> tshow b) x.stopLine
  SearchIndex x -> "SearchIndex " <> quoted x.query
  LookupSource x -> "LookupSource " <> x.query
  ReplaceText x -> "ReplaceText in " <> x.path <> " (" <> tshow (T.length x.replace) <> " characters replaced by " <> tshow (T.length x.with) <> ")"
  WriteFile x -> "WriteFile " <> x.path <> " (" <> tshow (T.length x.text) <> " characters)"
  Check -> "Check"
  Finish x -> "Finish: " <> T.take 200 x.summary
  where
    quoted t = "\"" <> T.take 200 t <> "\""

encodeText :: Value -> Text
encodeText = TE.decodeUtf8With TE.lenientDecode . BL.toStrict . encode

tshow :: (Show a) => a -> Text
tshow = T.pack . show
