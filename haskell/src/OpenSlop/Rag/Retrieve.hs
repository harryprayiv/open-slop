-- | Questions in, cited answers out, alone or as a conversation.
--
-- ============================================================================
-- ONE TURN
-- ============================================================================
--
--   1. With earlier turns, the chat model first rewrites the new question
--      as one that stands alone ("and the port?" becomes "what port does
--      the gateway listen on?"), because the search sees only the question
--      and a follow-up on its own finds nothing. Without earlier turns the
--      question is searched as asked.
--   2. 'retrieve' embeds that query and runs the hybrid search, within the
--      scope given, for up to 'depth' candidates.
--   3. 'relevant' drops hits whose vector is far from the question's
--      compared with the closest hit, the caller keeps at most as many as
--      it asks for (llmq-index's --sources), and 'packSources' keeps as
--      many of those as the model's capacity leaves room for after the
--      conversation and the answer.
--   4. 'answerStream' sends the instructions with the numbered sources, the
--      earlier turns and the question, and streams the answer as it comes.
--      Answers are not capped; see "OpenSlop.Capacity".
--   5. 'citedSources' reads the source numbers back out of the answer, so a
--      caller can show what was used and flag an answer that cites nothing
--      or cites a number it was never given.
--
-- Every server here is a 'Lan'; see "OpenSlop.Rag.Locality". The request
-- itself is made by "OpenSlop.ChatStream".
module OpenSlop.Rag.Retrieve
  ( Retrieval (..)
  , retrieve
  , Chat (..)
  , Answer (..)
  , historyChars
  , relevant
  , relevanceMargin
  , packSources
  , condense
  , answerStream
  , buildMessages
  , citedSources
  , judgeCitations
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Char (isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import OpenSlop.Capacity (Capacity (..), promptCharsWithin)
import OpenSlop.ChatStream (Ask (..), Chat (..), plainAsk, streamChat)
import OpenSlop.Http (Client)
import OpenSlop.Rag.Embed (Embedder (..), Purpose (..), embed)
import OpenSlop.Rag.Store (Connection, Hit (..), search)

data Retrieval = Retrieval
  { depth :: Int
  -- ^ candidates taken from each half of the hybrid search
  , limit :: Int
  -- ^ hits returned after fusion, before packing
  , scope :: [Text]
  -- ^ path prefixes; empty means the whole index
  }

retrieve :: Client -> Connection -> Embedder -> Retrieval -> Text -> IO (Either Text [Hit])
retrieve client conn e r query =
  embed client e ForQuery [query] >>= \case
    Left err -> pure (Left err)
    Right [v] -> Right <$> search conn e.model v query r.scope r.depth r.limit
    Right _ -> pure (Left "the embedding server returned no vector for the question")

data Answer = Answer
  { text :: Text
  , sources :: [Hit]
  , cited :: [Int]
  -- ^ source numbers the answer cites, 1-based, in the range given
  , invented :: [Int]
  -- ^ source numbers the answer cites that were never given
  , promptTokens :: Maybe Int
  -- ^ as the server counted them, when it says
  , promptChars :: Int
  }

instructions :: Text
instructions =
  T.unlines
    [ "You answer questions about the user's own files using the numbered sources below."
    , "Cite every claim that comes from a source with its number in square brackets, like [2]. End every sentence that uses a source with that source's number."
    , "If the sources do not contain the answer, say so plainly and say what they do contain; do not guess."
    , "Do not cite a number that is not in the list. Earlier turns of the conversation are context, not sources."
    ]

renderSource :: Int -> Hit -> Text
renderSource n h =
  "["
    <> T.pack (show n)
    <> "] "
    <> h.path
    <> (if T.null h.heading then "" else " (" <> h.heading <> ")")
    <> " lines "
    <> T.pack (show h.lineFrom)
    <> "-"
    <> T.pack (show h.lineTo)
    <> "\n"
    <> h.body
    <> "\n"

-- | Hits whose cosine similarity to the question is within
-- 'relevanceMargin' of the closest hit's, in their fused order.
--
-- This replaced a cut on the fused score (rank in the top ten of either
-- half), which could not reject anything: the word half matches any of the
-- question's words, so every candidate ranks somewhere, and with --depth 10
-- every one of them was "in the top ten". On 2026-10-16 that sent 19 of 19
-- candidates for "which machine holds the binary cache, and on what port?",
-- homebeacon and seedbox chunks among them, and the 7B answered without
-- citing any. Similarity is a measure of closeness rather than of rank, so
-- a candidate the word half found only because it contains "machine" is
-- dropped.
--
-- The margin is relative because absolute similarities depend on the
-- embedding model: two models put the same pair of texts at different
-- values, while the gap between a close chunk and an unrelated one is
-- comparable across them. llmq-index search prints each hit's
-- similarity, which is how to check the margin against a real index.
relevant :: [Hit] -> [Hit]
relevant hits = case hits of
  [] -> []
  _ -> filter (\h -> h.similarity >= best - relevanceMargin) hits
  where
    best = maximum (map (.similarity) hits)

-- | How far below the closest hit's similarity a hit may be and still be
-- sent to the model.
relevanceMargin :: Double
relevanceMargin = 0.08

-- | The best hits that fit, in order, given the characters already taken
-- by the conversation and the question.
packSources :: Capacity -> Maybe Double -> Int -> [Hit] -> [Hit]
packSources cap maxWait taken hits = go (budget - T.length instructions) (zip [1 ..] hits)
  where
    budget = promptCharsWithin cap 128 maxWait - taken
    go _ [] = []
    go room ((n, h) : rest)
      | size <= room = h : go (room - size) rest
      | otherwise = []
      where
        size = T.length (renderSource n h) + 1

-- | The messages for one turn: instructions and sources as the system
-- message, the earlier turns that fit, then the question. Earlier turns are
-- dropped oldest first so that they take at most half the prompt.
buildMessages :: Capacity -> Maybe Double -> [(Text, Text)] -> Text -> [Hit] -> ([Value], Int)
buildMessages cap maxWait history question hits = (msgs, chars)
  where
    system = instructions <> "\n" <> T.unlines (zipWith renderSource [1 ..] hits)
    half = promptCharsWithin cap 128 maxWait `div` 2
    kept = keepNewest half history
    msgs =
      [object ["role" .= ("system" :: Text), "content" .= system]]
        <> [object ["role" .= r, "content" .= c] | (r, c) <- kept]
        <> [object ["role" .= ("user" :: Text), "content" .= question]]
    chars = T.length system + sum [T.length c + 16 | (_, c) <- kept] + T.length question

keepNewest :: Int -> [(Text, Text)] -> [(Text, Text)]
keepNewest budget = reverse . go 0 . reverse
  where
    go _ [] = []
    go used ((r, c) : rest)
      | used + T.length c + 16 > budget = []
      | otherwise = (r, c) : go (used + T.length c + 16) rest

-- | The characters the conversation and question will take, for packing
-- the sources around them.
historyChars :: Capacity -> Maybe Double -> [(Text, Text)] -> Text -> Int
historyChars cap maxWait history question =
  sum [T.length c + 16 | (_, c) <- keepNewest (promptCharsWithin cap 128 maxWait `div` 2) history] + T.length question

-- | Rewrite a follow-up as a question that stands alone, using the
-- conversation. With no history the question is returned unchanged.
condense :: Client -> Chat -> Capacity -> [(Text, Text)] -> Text -> IO (Either Text Text)
condense _ _ _ [] q = pure (Right q)
condense client c cap history q = do
  let recent = keepNewest (promptCharsWithin cap 128 Nothing `div` 2) history
      convo = T.unlines [(if r == "user" then "User: " else "Assistant: ") <> t | (r, t) <- recent]
      msgs =
        [ object
            [ "role" .= ("system" :: Text)
            , "content"
                .= ( "Rewrite the user's last question so that it can be understood without the conversation, "
                       <> "for a search over their files. Reply with the rewritten question only, on one line." :: Text
                   )
            ]
        , object ["role" .= ("user" :: Text), "content" .= ("Conversation:\n" <> convo <> "\nLast question: " <> q)]
        ]
  out <- newIORef ("" :: Text)
  r <- streamChat client c cap (plainAsk msgs) {outputCap = Just 200} (\t -> modifyIORef' out (<> t)) (const (pure ()))
  rewritten <- T.strip . stripThink <$> readIORef out
  pure case r of
    Left e -> Left e
    Right ()
      | T.null rewritten -> Right q
      | otherwise -> Right (T.takeWhile (/= '\n') rewritten)
  where
    stripThink t = case T.breakOn "</think>" t of
      (_, rest) | not (T.null rest) -> T.drop 8 rest
      _ -> t

-- | Send one turn and stream the answer to the callback as it arrives.
answerStream
  :: Client
  -> Chat
  -> Capacity
  -> Maybe Double
  -> [(Text, Text)]
  -> Text
  -> [Hit]
  -> (Text -> IO ())
  -> IO (Either Text Answer)
answerStream client c cap maxWait history question hits onText = do
  let (msgs, chars) = buildMessages cap maxWait history question hits
  out <- newIORef ("" :: Text)
  counted <- newIORef Nothing
  r <- streamChat client c cap (plainAsk msgs) (\t -> modifyIORef' out (<> t) >> onText t) (writeIORef counted . Just)
  text <- readIORef out
  pt <- readIORef counted
  pure case r of
    Left e -> Left e
    Right () ->
      let (cited, invented) = judgeCitations (length hits) text
       in Right Answer {text, sources = hits, cited, invented, promptTokens = pt, promptChars = chars}

-- | Which cited numbers were given and which were not.
judgeCitations :: Int -> Text -> ([Int], [Int])
judgeCitations n text =
  let ns = citedSources text
      inRange k = k >= 1 && k <= n
   in (filter inRange ns, filter (not . inRange) ns)

-- | Every [n] or [n, m] in the answer.
citedSources :: Text -> [Int]
citedSources = sort . nub . go
  where
    go t = case T.breakOn "[" t of
      (_, rest) | T.null rest -> []
      (_, rest) ->
        let inner = T.takeWhile (/= ']') (T.drop 1 rest)
            after = T.drop 1 (T.dropWhile (/= ']') (T.drop 1 rest))
            nums =
              [ read (T.unpack n)
              | piece <- T.splitOn "," inner
              , let n = T.strip piece
              , not (T.null n)
              , T.length n <= 4
              , T.all isDigit n
              ]
            valid = T.all (\ch -> isDigit ch || ch == ',' || ch == ' ') inner && not (T.null inner)
         in (if valid then nums else []) <> go after