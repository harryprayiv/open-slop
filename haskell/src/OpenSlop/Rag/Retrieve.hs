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
--      earlier turns and the question, constrained to 'answerSchema': one
--      part for each thing the question asks, each with claims citing the
--      sources they come from, or with a gap saying what the sources lack.
--      The server turns the schema into a grammar, so a claim without a
--      source, a source number that was not given, or a part with neither
--      a claim nor a gap cannot be produced at all. Answers are not capped;
--      see "OpenSlop.Capacity".
--   5. The reply is decoded into an 'Answer' and rendered as text with the
--      numbers after each claim.
--
-- Until 2026-10-17 the answer was free text and 'citedSources' read the
-- numbers back out of it afterwards. A 7B often wrote none, and when it
-- wrote one it covered the whole answer: "blade, port 8080 [1]" cited the
-- source for the port and not the one that named blade. Checking after the
-- fact could only warn; the schema makes every claim carry its own sources
-- in the same way the agent's decisions are typed (OpenSlop.Agent.Action).
-- 'citedSources' stays for reading numbers out of earlier free-text turns.
--
-- Every server here is a 'Lan'; see "OpenSlop.Rag.Locality". The request
-- itself is made by "OpenSlop.ChatStream".
module OpenSlop.Rag.Retrieve
  ( Retrieval (..)
  , retrieve
  , Chat (..)
  , Answer (..)
  , Claim (..)
  , Part (..)
  , answerSchema
  , decodeAnswer
  , renderAnswer
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

import Data.Aeson (FromJSON (..), Value (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Char (isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import OpenSlop.Capacity (Capacity (..), promptCharsWithin)
import OpenSlop.Catalogue (Engine (..))
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

-- | One statement of the answer and the sources it rests on. The field
-- names are in the order the grammar makes the model write them, which is
-- alphabetical: the claim first, then where it came from.
data Claim = Claim
  { claim :: Text
  , sources :: [Int]
  -- ^ 1-based numbers of the sources given, at least one
  }
  deriving stock (Eq, Show)

instance FromJSON Claim where
  parseJSON = withObject "claim" \o -> Claim <$> o .: "claim" <*> o .: "sources"

-- | One thing the question asks, and its answer: claims with sources, or
-- an empty list and a gap saying what the sources lack. Named so that the
-- grammar has the model write the question part first ("ask" sorts before
-- "claims" and "gap"), then answer it.
data Part = Part
  { ask :: Text
  , claims :: [Claim]
  , gap :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Part where
  parseJSON = withObject "part" \o -> Part <$> o .: "ask" <*> o .: "claims" <*> o .: "gap"

newtype Reply = Reply [Part]

instance FromJSON Reply where
  parseJSON = withObject "answer" \o -> Reply <$> o .: "parts"

data Answer = Answer
  { text :: Text
  -- ^ the parts rendered, each claim followed by its source numbers
  , parts :: [Part]
  , claims :: [Claim]
  -- ^ every part's claims, in order
  , sources :: [Hit]
  , cited :: [Int]
  -- ^ source numbers the claims cite, 1-based, in the range given
  , invented :: [Int]
  -- ^ source numbers outside the range; empty unless the server ignored
  -- the schema
  , promptTokens :: Maybe Int
  -- ^ as the server counted them, when it says
  , promptChars :: Int
  }

-- | The JSON Schema an answer from n sources must match.
--
-- The answer is a list of parts, one for each thing the question asks.
-- Each part is one of two shapes: at least one claim, each naming at least
-- one source from 1..n (an enum, so the grammar cannot produce another
-- number); or no claims and a gap that is not empty. A part therefore
-- cannot be left both unanswered and unexplained.
--
-- This replaced a single list of claims on 2026-10-17. Asked "which machine
-- holds the binary cache, and on what port?", the 7B answered the port,
-- left the machine out and left the gap empty, though the source naming
-- the machine was among those it was given. Writing each part of the
-- question before answering it makes the model account for every part.
answerSchema :: Int -> Value
answerSchema n =
  object
    [ "type" .= ("object" :: Text)
    , "properties"
        .= object
          [ "parts"
              .= object
                [ "type" .= ("array" :: Text)
                , "minItems" .= (1 :: Int)
                , "items" .= object ["anyOf" .= ([answered | n >= 1] <> [unanswered])]
                ]
          ]
    , "required" .= ["parts" :: Text]
    , "additionalProperties" .= False
    ]
  where
    part claimsSchema gapSchema =
      object
        [ "type" .= ("object" :: Text)
        , "properties"
            .= object
              [ "ask" .= object ["type" .= ("string" :: Text), "minLength" .= (1 :: Int)]
              , "claims" .= claimsSchema
              , "gap" .= gapSchema
              ]
        , "required" .= ["ask", "claims", "gap" :: Text]
        , "additionalProperties" .= False
        ]
    answered =
      part
        ( object
            [ "type" .= ("array" :: Text)
            , "minItems" .= (1 :: Int)
            , "items" .= claimSchema
            ]
        )
        (object ["type" .= ("string" :: Text)])
    unanswered =
      part
        (object ["type" .= ("array" :: Text), "maxItems" .= (0 :: Int)])
        (object ["type" .= ("string" :: Text), "minLength" .= (1 :: Int)])
    claimSchema =
      object
        [ "type" .= ("object" :: Text)
        , "properties"
            .= object
              [ "claim" .= object ["type" .= ("string" :: Text), "minLength" .= (1 :: Int)]
              , "sources"
                  .= object
                    [ "type" .= ("array" :: Text)
                    , "items" .= object ["enum" .= [1 .. max 1 n]]
                    , "minItems" .= (1 :: Int)
                    ]
              ]
        , "required" .= ["claim", "sources" :: Text]
        , "additionalProperties" .= False
        ]

-- | The reply, read against the number of sources given: its parts, and
-- the source numbers cited in range and out of it. A code fence around it
-- is tolerated; anything that is not the schema's shape is an error with
-- the start of what came back.
decodeAnswer :: Int -> Text -> Either Text ([Part], [Int], [Int])
decodeAnswer n raw =
  case Aeson.eitherDecodeStrict (TE.encodeUtf8 (unfence (T.strip raw))) of
    Left err -> Left ("the answer is not the expected JSON (" <> T.pack err <> "): " <> T.take 200 raw)
    Right (Reply ps) ->
      let cleaned = [p {gap = T.strip p.gap} | p <- ps]
          ns = sort (nub (concatMap (.sources) (concatMap (.claims) cleaned)))
          inRange k = k >= 1 && k <= n
       in Right (cleaned, filter inRange ns, filter (not . inRange) ns)
  where
    unfence t
      | "```" `T.isPrefixOf` t = T.strip (T.dropWhileEnd (== '`') (T.dropWhile (/= '\n') t))
      | otherwise = t

-- | Each part as its question, then its claims with their sources, then
-- what the sources do not say about it. A question with one part is shown
-- without the question repeated.
renderAnswer :: [Part] -> Text
renderAnswer = \case
  [p] -> T.intercalate "\n" (body "" p)
  ps -> T.intercalate "\n" (concatMap (\p -> p.ask : body "  " p) ps)
  where
    body indent p =
      [ indent <> c.claim <> " " <> T.concat ["[" <> T.pack (show k) <> "]" | k <- c.sources]
      | c <- p.claims
      ]
        <> [indent <> "Not in the sources: " <> p.gap | not (T.null p.gap)]

instructions :: Text
instructions =
  T.unlines
    [ "You answer questions about the user's own files using the numbered sources below."
    , "Reply with JSON. parts has one entry for each thing the question asks: a question with two parts (\"which machine, and on what port?\") has two entries."
    , "In each part, ask restates that one thing; claims are statements answering it, each with the numbers of the sources it comes from; gap says what the sources do not tell about it, or is empty."
    , "Give one claim per fact, so each claim lists the sources for that fact alone. Read every source before deciding a part is not answered."
    , "Only state what a source says. If the sources do not answer a part, give it no claims and say what is missing in its gap; do not guess."
    , "Earlier turns of the conversation are context, not sources."
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

-- | Send one turn, constrained to 'answerSchema', and stream the raw reply
-- to the callback as it arrives, for progress; the decoded 'Answer' is the
-- result. hailo-ollama takes no schema and is refused.
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
answerStream _ c _ _ _ _ _ _
  | c.engine == HailoOllama = pure (Left "hailo-ollama takes no schema, so it cannot give a cited answer; use an ollama or llama-server endpoint")
answerStream client c cap maxWait history question hits onText = do
  let (msgs, chars) = buildMessages cap maxWait history question hits
      ask = (plainAsk msgs) {schema = Just (answerSchema (length hits))}
  out <- newIORef ("" :: Text)
  counted <- newIORef Nothing
  r <- streamChat client c cap ask (\t -> modifyIORef' out (<> t) >> onText t) (writeIORef counted . Just)
  raw <- readIORef out
  pt <- readIORef counted
  pure case r of
    Left e -> Left e
    Right () -> do
      (parts, cited, invented) <- decodeAnswer (length hits) raw
      Right Answer {text = renderAnswer parts, parts, claims = concatMap (.claims) parts, sources = hits, cited, invented, promptTokens = pt, promptChars = chars}

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