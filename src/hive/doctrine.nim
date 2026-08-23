## The doctrine: the batched-over-bodies vector one colony plays for one turn,
## its tolerant parser, its repair rules, and the integer coefficient table the
## ant kernel reads.
##
## Every string that can reach the replay is truncated on RUNE boundaries.
## A byte-truncated multi-byte character is exactly the bug that makes replay
## bytes render in a browser and fail a strict JSON parser.

import std/[json, strutils, unicode]
import types

const
  DefaultScouts* = 40
  DefaultTrailGain* = 50
  DefaultPoach* = 15
  DefaultSpread* = 40
  DefaultLayFood* = 70
  DefaultLayHome* = 50

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts on a rune boundary, never a byte boundary.
  let cleaned = text.replace("\n", " ").replace("\r", " ").strip()
  if cleaned.runeLen <= limit:
    return cleaned
  cleaned.runeSubStr(0, limit)

proc clamp100(value: int): int {.inline.} =
  if value < 0: 0 elif value > 100: 100 else: value

proc defaultDoctrine*(): Doctrine =
  Doctrine(
    scouts: DefaultScouts,
    trailGain: DefaultTrailGain,
    poach: DefaultPoach,
    spread: DefaultSpread,
    layFood: DefaultLayFood,
    layHome: DefaultLayHome,
    recall: false,
    hasFocus: false,
    focusBx: 0,
    focusBy: 0,
    focusWeight: 0,
    note: "",
    say: ""
  )

proc coefficients*(doctrine: Doctrine, antsPerColony: int): Coefficients =
  ## The exact integer table from the design note. Every output is inside its
  ## stated range for every legal doctrine, which `tests/test_baselines.nim`
  ## asserts over 500 random views.
  Coefficients(
    alphaFood: doctrine.trailGain * 4,
    alphaRival: doctrine.poach * 3,
    alphaHome: doctrine.spread * 3,
    alphaFwd: 320 - doctrine.spread * 2,
    alphaNoise: 40 + (100 - doctrine.trailGain) * 4,
    betaHome: 200 + doctrine.trailGain * 2,
    layFood: 40 + doctrine.layFood * 3,
    layHome: 20 + doctrine.layHome * 2,
    scoutCount: min(antsPerColony,
      (doctrine.scouts * antsPerColony + 50) div 100)
  )

# ---- tolerant parsing -------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the outermost balanced `{...}` out of a model reply, tolerating
  ## markdown fences and prose prefixes (bullwhip's shape, widened to a brace
  ## scan so a prose paragraph containing a `}` cannot truncate the object).
  var start = -1
  var depth = 0
  var inString = false
  var escaped = false
  for index, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0:
        start = index
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          return parseJson(text[start .. index])
    else: discard
  var head = text.strip()
  if head.runeLen > 160:
    head = head.runeSubStr(0, 160) & "..."
  raise newException(HiveError,
    "no JSON object in response: " & head.replace("\n", " "))

proc readPercent(node: JsonNode, fallback: int): int =
  ## Accepts an int, a float, a numeric string, and `"70%"`.
  if node.isNil or node.kind == JNull:
    return fallback
  case node.kind
  of JInt:
    clamp100(node.getInt())
  of JFloat:
    clamp100(int(node.getFloat()))
  of JBool:
    if node.getBool(): 100 else: 0
  of JString:
    var text = node.getStr().strip()
    if text.endsWith("%"):
      text = text[0 ..< text.high].strip()
    if text.len == 0:
      return fallback
    try:
      clamp100(int(parseFloat(text)))
    except ValueError:
      fallback
  else:
    fallback

proc readBool(node: JsonNode): bool =
  if node.isNil or node.kind == JNull:
    return false
  case node.kind
  of JBool: node.getBool()
  of JInt: node.getInt() != 0
  of JFloat: node.getFloat() != 0.0
  of JString:
    case node.getStr().strip().toLowerAscii()
    of "true", "1", "yes", "on": true
    else: false
  else: false

proc readFocus(node: JsonNode, doctrine: var Doctrine) =
  ## `[bx, by]` or `{"bx":…,"by":…}`; anything else is `null`.
  doctrine.hasFocus = false
  doctrine.focusBx = 0
  doctrine.focusBy = 0
  if node.isNil or node.kind == JNull:
    return
  var bx = -1
  var by = -1
  if node.kind == JArray and node.len == 2:
    bx = readPercent(node[0], -1)
    by = readPercent(node[1], -1)
    ## readPercent clamps to 0..100 which is wider than the block grid; the
    ## clamp below narrows it and a non-numeric entry stays -1.
    if node[0].kind notin {JInt, JFloat, JString}: bx = -1
    if node[1].kind notin {JInt, JFloat, JString}: by = -1
  elif node.kind == JObject and (node.hasKey("bx") or node.hasKey("by")):
    bx = readPercent(node{"bx"}, -1)
    by = readPercent(node{"by"}, -1)
  else:
    return
  if bx < 0 or by < 0:
    return
  doctrine.hasFocus = true
  doctrine.focusBx = min(BlockCols - 1, max(0, bx))
  doctrine.focusBy = min(BlockRows - 1, max(0, by))

proc hasDoctrineKey*(node: JsonNode): bool =
  ## True when the object carries at least one recognised doctrine key.
  if node.isNil or node.kind != JObject:
    return false
  for key in ["scouts", "trail_gain", "poach", "spread", "lay_food",
      "lay_home", "recall", "focus", "focus_weight", "note", "say"]:
    if node.hasKey(key):
      return true
  false

proc repairDoctrine*(
  node: JsonNode,
  previous: Doctrine,
  hasPrevious: bool
): Doctrine =
  ## Parses and repairs one doctrine object. Missing or non-numeric integer
  ## fields fall back to the previous turn's value, or the turn-0 default.
  ## The result is always legal, so it is what gets installed AND recorded -
  ## the replay never depends on re-running the repair.
  let base = if hasPrevious: previous else: defaultDoctrine()
  result = base
  result.note = ""
  result.say = ""
  result.scouts = readPercent(node{"scouts"}, base.scouts)
  result.trailGain = readPercent(node{"trail_gain"}, base.trailGain)
  result.poach = readPercent(node{"poach"}, base.poach)
  result.spread = readPercent(node{"spread"}, base.spread)
  result.layFood = readPercent(node{"lay_food"}, base.layFood)
  result.layHome = readPercent(node{"lay_home"}, base.layHome)
  result.recall = readBool(node{"recall"})
  ## Recall may not run two turns in a row: it is the reset, not a strategy.
  if hasPrevious and previous.recall:
    result.recall = false
  readFocus(node{"focus"}, result)
  result.focusWeight = readPercent(node{"focus_weight"}, base.focusWeight)
  if not result.hasFocus:
    result.focusWeight = 0
  result.note = truncateRunes(node{"note"}.getStr(), MaxNoteRunes)
  result.say = truncateRunes(node{"say"}.getStr(), MaxSayRunes)

proc parseDoctrine*(
  text: string,
  previous: Doctrine,
  hasPrevious: bool
): Doctrine =
  ## Tolerant end to end: fences, prose prefixes, numeric strings, `"70%"`,
  ## `focus` as an object. Raises only when no object carrying a recognised
  ## doctrine key can be recovered at all.
  let node = extractJsonObject(text)
  if not hasDoctrineKey(node):
    raise newException(HiveError,
      "reply carried no usable doctrine key")
  repairDoctrine(node, previous, hasPrevious)

proc toJson*(doctrine: Doctrine): JsonNode =
  result = %*{
    "scouts": doctrine.scouts,
    "trail_gain": doctrine.trailGain,
    "poach": doctrine.poach,
    "spread": doctrine.spread,
    "lay_food": doctrine.layFood,
    "lay_home": doctrine.layHome,
    "recall": doctrine.recall,
    "focus_weight": doctrine.focusWeight,
    "note": doctrine.note,
    "say": doctrine.say
  }
  result["focus"] =
    if doctrine.hasFocus: %[doctrine.focusBx, doctrine.focusBy]
    else: newJNull()

proc fromJson*(node: JsonNode): Doctrine =
  ## Reads a recorded doctrine back out of a replay. Recorded doctrines are
  ## already repaired, so this is a strict-ish read with the same clamps.
  result = repairDoctrine(node, defaultDoctrine(), false)

proc isLegal*(doctrine: Doctrine): bool =
  ## The schema assertion `tests/test_baselines.nim` runs on every emission.
  if doctrine.scouts notin 0 .. 100: return false
  if doctrine.trailGain notin 0 .. 100: return false
  if doctrine.poach notin 0 .. 100: return false
  if doctrine.spread notin 0 .. 100: return false
  if doctrine.layFood notin 0 .. 100: return false
  if doctrine.layHome notin 0 .. 100: return false
  if doctrine.focusWeight notin 0 .. 100: return false
  if doctrine.hasFocus:
    if doctrine.focusBx notin 0 ..< BlockCols: return false
    if doctrine.focusBy notin 0 ..< BlockRows: return false
  elif doctrine.focusWeight != 0:
    return false
  if doctrine.note.runeLen > MaxNoteRunes: return false
  if doctrine.say.runeLen > MaxSayRunes: return false
  true
