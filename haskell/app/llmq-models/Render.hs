-- | The screens: the table, the panel for the selected model, the graph,
-- and the restraint answers page. Pure functions from rows to lines.
--
-- Part of llmq-models; Main describes the program.
module Render
  ( tableLines
  , panel
  , Metric (..)
  , graphLines
  , answersLines
  , statusLine
  , resident
  ) where

import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Time.LocalTime (ZonedTime, zonedTimeToUTC)
import Live
import Models
import Style

-- | Whether a model is in memory on its server right now. ollama reports
-- "sully:latest" for the model the catalogue calls "sully", so the tag is
-- dropped before comparing. llama-server has exactly one model, resident
-- whenever the server answers /health with ok. The NPU does not say.
resident :: Live -> Row -> Bool
resident live r = case r.backend of
  "cpu" -> any (\l -> stripLatest l.name == stripLatest r.model) live.loaded
  "llamacpp" -> live.llamaHealth == "ok"
  _ -> False
  where
    stripLatest t = maybe t id (T.stripSuffix ":latest" t)

-- | One line about the machine itself: each server answering or not, load,
-- memory, temperature, what is in memory and for how long, and how old
-- this picture is.
statusLine :: UTCTime -> Int -> Live -> Text
statusLine now width live =
  clip width $
    case live.fetchedAt of
      Nothing -> fg cMuted " asking oracle..."
      Just t ->
        -- Most useful first, because a narrow terminal cuts from the right:
        -- which servers answer, what is in memory, then the machine.
        T.intercalate
          (fg cMuted "  ")
          ( [ bold (fg cText (" " <> (if T.null live.host then "oracle" else live.host)))
            , dot live.ollamaUp <> fg cGrey " ollama"
            , dot live.hailoUp <> fg cGrey " npu"
            , llama
            , inMemory
            ]
              <> machine
              <> [fg cMuted (ago t)]
          )
  where
    dot up = if up then fg cGreen "●" else fg cRed "●"
    llama = case live.llamaHealth of
      "ok" -> fg cGreen "●" <> fg cGrey (if live.llamaBusy then " llama-server busy" else " llama-server idle")
      "down" -> fg cMuted "○ llama-server off"
      s -> fg cYellow "●" <> fg cGrey (" llama-server " <> s)
    machine
      | not live.telemetry = [fg cMuted "no telemetry"]
      | otherwise =
          [ fg cGrey "load " <> fg cText (maybe "-" (fmt "%.1f") live.load1) <> fg cMuted (maybe "" (\c -> "/" <> T.pack (show c)) live.cores)
          , fg cGrey "free " <> fg cText (maybe "-" (\a -> fmt "%.1f" (a / 1e9)) live.memAvailable) <> fg cMuted (maybe "" (\m -> "/" <> fmt "%.0fG" (m / 1e9)) live.memTotal)
          , maybe (fg cMuted "-") (\c -> fg (if c >= 75 then cRed else if c >= 65 then cYellow else cText) (fmt "%.0f°C" c)) live.tempC
          ]
    inMemory = case live.loaded of
      [] -> fg cMuted "nothing in memory"
      ls ->
        fg cGrey "◉ "
          <> T.intercalate
            ", "
            [ fg cGreen l.name <> fg cMuted (maybe "" untilUnload l.expiresAt)
            | l <- ls
            ]
    untilUnload e = case iso8601ParseM (T.unpack e) :: Maybe ZonedTime of
      Just z ->
        let s = realToFrac (diffUTCTime (zonedTimeToUTC z) now) :: Double
         in if s > 0 then " for " <> duration s else ""
      Nothing -> ""
    ago t =
      let s = realToFrac (diffUTCTime now t) :: Double
       in T.pack (show (max 0 (round s :: Int))) <> "s ago"

-- | Column layout shared by the header and every row.
columns :: [(Text, Int, Bool)]
columns =
  -- (heading, width, right-aligned)
  [ ("", 2, False)
  , ("backend", 11, False)
  , ("model", 31, False)
  , ("params", 7, True)
  , ("decode", 20, False)
  , ("prefill", 8, True)
  , ("load", 7, True)
  , ("restraint", 12, False)
  , ("feel", 14, False)
  ]

layout :: [Text] -> Text
layout cells =
  T.intercalate
    " "
    [ (if right then padL w else padTo w) c
    | ((_, w, right), c) <- zip columns cells
    ]

-- | The table. The first predicate says which models are in memory right
-- now, marked with a filled dot beside the name; the second which are
-- marked for a comparison chat, shown with a + in the first column.
--
-- The header's model heading carries the same two-space indent as the
-- in-memory slot in front of each name, so the headings sit over their
-- columns.
tableLines :: (Row -> Bool) -> (Row -> Bool) -> Int -> [Row] -> Maybe Int -> [Text]
tableLines inMemory marked width rows selected =
  clip width (fg cGrey (layout [if h == "model" then "  model" else h | (h, _, _) <- columns])) : zipWith line [0 ..] rows
  where
    maxDecode = maximum (1 : mapMaybe (.decode) rows)
    line i r =
      let isSel = selected == Just i
          feel = feelOf r
          cells =
            [ (if isSel then fg cAccent "▶" else " ") <> (if marked r then bold (fg cAccent "+") else " ")
            , fg (backendColour r.backend) ("● " <> r.backend)
            , (if inMemory r then fg cGreen "◉ " else fg cMuted "  ") <> (if isSel then bold else id) (fg cText (T.take 29 r.model))
            , maybe (fg cMuted "-") (fg cText . showParams) r.params
            , maybe
                (fg cMuted "-")
                (\d -> fg (feelColour feel) (gauge 12 (d / maxDecode)) <> " " <> fg cText (fmt "%5.2f" d))
                r.decode
            , maybe (fg cMuted "-") (fg cText . fmt "%.1f" . snd) r.prefill
            , maybe (fg cMuted "-") (\l -> fg cText (fmt "%.0f s" l)) r.load
            , restraintCell r
            , fg (feelColour feel) (feelName feel)
            ]
          body = layout cells
       in clip width (if isSel then bg cSel (padTo width body) else body)

restraintCell :: Row -> Text
restraintCell r = case stiffness r of
  Nothing -> fg cMuted "-"
  Just (n, total) ->
    let c | n == 0 = cGreen | n <= 1 = cYellow | otherwise = cRed
     in fg c (T.replicate n "●") <> fg cMuted (T.replicate (total - n) "○")

-- ===========================================================================
-- The panel for the selected model
-- ===========================================================================

panel :: Bool -> Int -> Row -> [Text]
panel inMemory width r =
  box
    boxW
    (fg (backendColour r.backend) ("● " <> r.backend) <> "  " <> bold (fg cText r.model) <> "  " <> fg (feelColour (feelOf r)) (feelName (feelOf r)))
    ( zipWith
        (\a b -> padTo half a <> "  " <> b)
        (pad leftCol)
        (pad rightCol)
        <> [""]
        <> estimateLines
        <> [fg cMuted l | s <- [r.summary], not (T.null s), l <- wrap (boxW - 4) s]
        <> [fg cRed "problem " <> fg cText (T.take (boxW - 12) (T.takeWhile (/= '\n') p)) | p <- r.problems]
    )
  where
    boxW = min width 118
    half = (boxW - 6) `div` 2
    pad xs = xs <> replicate (max (length leftCol) (length rightCol) - length xs) ""
    kv k v = fg cGrey (padTo 9 k) <> v
    leftCol =
      [ bold (fg cAccent "speed")
      , kv "decode" (maybe (fg cMuted "not measured") (\d -> fg (feelColour (feelOf r)) (fmt "%.2f tok/s" d)) r.decode)
      , kv "prefill" (maybe (fg cMuted "not measured") (\(n, s) -> fg cText (fmt "%.1f tok/s" s) <> fg cMuted (" at " <> T.pack (show n) <> " tokens")) r.prefill)
      , kv "warm" (maybe (fg cMuted "-") (\w -> fg cText (fmt "%.1f s" w) <> fg cMuted " to re-read it") r.warm)
      , kv "load" (maybe (fg cMuted (if T.null r.loadNote then "-" else "resident")) (\l -> fg cText (fmt "%.0f s" l) <> fg cMuted " into memory") r.load)
      , ""
      , bold (fg cAccent "model")
      , kv "params" (maybe (fg cMuted "unknown") (\p -> fg cText (showParams p) <> fg cMuted (if snd p then "" else " from the name")) r.params)
      , kv "quant" (fg cText (orDash r.quant) <> (if T.null r.family then "" else fg cMuted ("  " <> r.family)))
      , kv "size" (maybe (fg cMuted "-") (\b -> fg cText (fmt "%.1f GB" (b / 1e9))) r.sizeBytes)
      , kv "window" (maybe (fg cMuted "-") (\w -> fg cText (T.pack (show w)) <> fg cMuted " tokens") r.window)
      , kv "schema" (fg (if r.schema == "honoured" then cGreen else cGrey) r.schema)
      , kv "licence" (fg cText (T.take (half - 10) r.licence))
      ]
    rightCol =
      [ bold (fg cAccent "restraint") <> fg cMuted "   p: read the answers"
      ]
        <> if null r.probes
          then [fg cMuted "not probed"]
          else
            [ (if p.refused then fg cRed "✗ " else fg cGreen "✓ ")
                <> fg cText (padTo 12 p.name)
                <> fg cMuted (if p.name == "opinion" then "not counted" else if p.refused then "refused" else "answered")
            | p <- r.probes
            ]
              <> [ ""
                 , case stiffness r of
                     Just (0, _) -> fg cGreen "answers everything it was asked"
                     Just (n, t) -> fg (if n <= 1 then cYellow else cRed) (T.pack (show n) <> " of " <> T.pack (show t) <> " refused")
                     Nothing -> ""
                 ]
    estimateLines = case (r.decode, r.prefill) of
      (Just d, Just (_, p)) ->
        let prompt = 60 / p
            answer = 200 / d
         in [ bold (fg cAccent "a typical ask") <> (if inMemory then fg cGreen "   in memory now, so the warm figure applies" else "")
            , fg cText ("warm  " <> duration (prompt + answer))
                <> fg cMuted ("   " <> duration prompt <> " to read the question, " <> duration answer <> " for 200 tokens")
            , case r.load of
                Just l -> fg cText ("cold  " <> duration (l + prompt + answer)) <> fg cMuted ("   plus " <> duration l <> " to load the model first")
                Nothing -> fg cMuted "cold  no load: this server keeps its model resident"
            ]
      _ -> [fg cMuted "no measurement, so no estimate"]
    orDash t = if T.null t then "-" else t

-- | A rounded box with a title in its top edge.
box :: Int -> Text -> [Text] -> [Text]
box w title body =
  [ fg cMuted "╭─ " <> title <> fg cMuted (" " <> T.replicate (max 0 (w - 5 - visibleLength title)) "─" <> "╮")
  ]
    <> [fg cMuted "│ " <> padTo (w - 4) l <> fg cMuted " │" | l <- body]
    <> [fg cMuted ("╰" <> T.replicate (w - 2) "─" <> "╯")]

-- ===========================================================================
-- The graph
-- ===========================================================================

data Metric = MDecode | MPrefill
  deriving stock (Eq)

metricName :: Metric -> Text
metricName = \case
  MDecode -> "decode tok/s"
  MPrefill -> "prefill tok/s"

metricOf :: Metric -> Row -> Maybe Double
metricOf = \case
  MDecode -> (.decode)
  MPrefill -> fmap snd . (.prefill)

-- | Parameters across on a log scale, the chosen speed up. For decode, the
-- conversational line at 5 tok/s is drawn across. Points that land on the
-- same spot are nudged right so every number stays readable.
graphLines :: Int -> Int -> Metric -> [Row] -> Int -> [Text]
graphLines width height metric rows selected =
  [fg cGrey ("  parameters (log) across, " <> metricName metric <> " up" <> "   y switches the axis"), ""]
    <> plot
    <> [fg cMuted (T.replicate 7 " " <> "└" <> T.replicate gw "─"), fg cGrey xLabels, ""]
    <> legend
    <> unplotted
  where
    numbered = zip [1 :: Int ..] rows
    pts = [(i, fst p, v, r) | (i, r) <- numbered, Just p <- [r.params], Just v <- [metricOf metric r]]
    ymax = maximum (1 : [v | (_, _, v, _) <- pts]) * 1.1
    gw = max 20 (width - 12)
    gh = max 6 (min 22 (height - 9 - length legend - length unplotted))
    colOf p = min (gw - 1) (max 0 (round ((log (max 1 p)) / log 10 * fromIntegral (gw - 1))))
    rowOfV v = min (gh - 1) (max 0 (gh - 1 - round (v / ymax * fromIntegral (gh - 1))))
    labelOf i = T.pack (show i)
    isSel r = case drop selected rows of
      (s : _) -> s.model == r.model && s.backend == r.backend
      [] -> False
    placed = foldl place [] pts
    place acc (i, p, v, r) =
      let w = T.length (labelOf i)
          y = rowOfV v
          x0 = colOf p
          free x = x >= 0 && x + w <= gw && and [not (taken x' y) | x' <- [x - 1 .. x + w]]
          taken x' y' = or [y'' == y' && x' >= xs && x' < xs + T.length (labelOf j) | (j, xs, y'', _) <- acc]
       in case filter free (concat [[x0 + d, x0 - d] | d <- [0 .. gw]]) of
            (x : _) -> acc <> [(i, x, y, r)]
            [] -> acc
    plot = [yLabel y <> fg cMuted " │" <> T.concat (render y 0) | y <- [0 .. gh - 1]]
    render y x
      | x >= gw = []
      | otherwise =
          case [(i, r) | (i, xs, y', r) <- placed, y' == y, xs == x] of
            ((i, r) : _) ->
              let s = labelOf i
                  shown = if isSel r then rev (bold (fg (feelColour (feelOf r)) s)) else bold (fg (feelColour (feelOf r)) s)
               in shown : render y (x + T.length s)
            [] -> (if metric == MDecode && y == rowOfV 5 then fg cMuted "┈" else " ") : render y (x + 1)
    yLabel y
      | y == 0 = fg cGrey (padL 6 (fmt "%.0f" ymax))
      | y == gh - 1 = fg cGrey (padL 6 "0")
      | metric == MDecode && y == rowOfV 5 = fg cGreen (padL 6 "5 conv")
      | otherwise = T.replicate 6 " "
    xLabels =
      T.replicate 8 " "
        <> T.concat [padTo (colOf b' - colOf a) (T.pack (show (round a :: Int)) <> "B") | (a, b') <- zip [1, 2, 3, 5, 7 :: Double] [2, 3, 5, 7, 10 :: Double]]
        <> "10B"
    legendEntry (i, _, _, r) =
      padL 3 (bold (fg (feelColour (feelOf r)) (labelOf i))) <> " " <> fg (backendColour r.backend) "●" <> " " <> padTo 36 (fg cText (T.take 34 (r.backend <> "/" <> r.model)))
    legend
      | width >= 90 = pairUp (map legendEntry pts)
      | otherwise = map legendEntry pts
    pairUp (a : b : rest) = (a <> "  " <> b) : pairUp rest
    pairUp [a] = [a]
    pairUp [] = []
    unplotted = case [r | (_, r) <- numbered, not (isJust r.params && isJust (metricOf metric r))] of
      [] -> []
      rs -> ["", fg cMuted ("not plotted: " <> T.intercalate ", " [r.model | r <- rs])]

-- ===========================================================================
-- The restraint answers page
-- ===========================================================================

answersLines :: Int -> Row -> [Text]
answersLines width r =
  concat
    [ [ (if p.refused then fg cRed "✗ " else fg cGreen "✓ ")
          <> bold (fg cText p.name)
          <> fg cMuted (if p.name == "opinion" then "   not counted" else if p.refused then "   judged a refusal" else "   judged an answer")
      ]
        <> [fg cText ("   " <> l) | l <- take 4 (wrap (width - 6) p.answer)]
        <> [""]
    | p <- r.probes
    ]