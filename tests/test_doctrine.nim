## Tolerant parsing, repair, and RUNE-boundary truncation. A byte-truncated
## multi-byte character renders fine in a browser and fails a strict JSON
## parser, which is exactly the bug that loses a replay.

import std/[json, strutils, unicode]
import support/helpers

proc parsed(text: string, previous = defaultDoctrine(),
    hasPrevious = false): Doctrine =
  parseDoctrine(text, previous, hasPrevious)

proc main() =
  block prosePrefixed:
    let doctrine = parsed("Sure! Here is my plan for this turn.\n" &
      "{\"scouts\": 20, \"trail_gain\": 80, \"poach\": 5, \"spread\": 30, " &
      "\"lay_food\": 90, \"lay_home\": 60, \"recall\": false, " &
      "\"focus\": [3, 4], \"focus_weight\": 70, \"note\": \"go\", " &
      "\"say\": \"go\"}\nHope that helps!")
    checkEqual(doctrine.scouts, 20, "prose-prefixed JSON parses")
    checkEqual(doctrine.trailGain, 80, "trail_gain")
    checkEqual(doctrine.focusBx, 3, "focus bx")
    report("prose before and after the object is tolerated")

  block fenced:
    let doctrine = parsed("```json\n{\"scouts\": 33, \"trail_gain\": 44}\n```")
    checkEqual(doctrine.scouts, 33, "fenced JSON parses")
    checkEqual(doctrine.trailGain, 44, "fenced trail_gain")
    report("markdown fences are stripped")

  block percentStrings:
    let doctrine = parsed("{\"scouts\": \"70%\", \"trail_gain\": \"12\", " &
      "\"poach\": 8.9}")
    checkEqual(doctrine.scouts, 70, "\"70%\" parses as 70")
    checkEqual(doctrine.trailGain, 12, "a numeric string parses")
    checkEqual(doctrine.poach, 8, "a float truncates to an int")
    report("numeric strings, percentages and floats are accepted")

  block focusShapes:
    checkEqual(parsed("{\"focus\": {\"bx\": 9, \"by\": 5}, " &
      "\"focus_weight\": 50}").focusBx, 9, "focus as an object")
    checkEqual(parsed("{\"focus\": {\"bx\": 9, \"by\": 5}, " &
      "\"focus_weight\": 50}").focusBy, 5, "focus as an object, by")
    let clamped = parsed("{\"focus\": [99, 99], \"focus_weight\": 50}")
    checkEqual(clamped.focusBx, BlockCols - 1, "an out-of-range bx clamps")
    checkEqual(clamped.focusBy, BlockRows - 1, "an out-of-range by clamps")
    let arity = parsed("{\"focus\": [1, 2, 3], \"focus_weight\": 50}")
    check(not arity.hasFocus, "the wrong arity makes focus null")
    checkEqual(arity.focusWeight, 0, "focus_weight is forced 0 with no focus")
    let text = parsed("{\"focus\": \"middle\", \"focus_weight\": 50}")
    check(not text.hasFocus, "a non-array, non-object focus is null")
    report("focus accepts both shapes, clamps, and nulls anything else")

  block integerRepair:
    let clampedInts = parsed("{\"scouts\": -40, \"trail_gain\": 300}")
    checkEqual(clampedInts.scouts, 0, "a negative integer clamps to 0")
    checkEqual(clampedInts.trailGain, 100, "a 300-valued integer clamps to 100")
    report("out-of-range integers clamp")

  block missingFields:
    let turnZero = parsed("{\"note\": \"nothing else\"}")
    checkEqual(turnZero.scouts, DefaultScouts, "turn 0 default scouts")
    checkEqual(turnZero.trailGain, DefaultTrailGain, "turn 0 default trail")
    checkEqual(turnZero.poach, DefaultPoach, "turn 0 default poach")
    checkEqual(turnZero.spread, DefaultSpread, "turn 0 default spread")
    checkEqual(turnZero.layFood, DefaultLayFood, "turn 0 default lay_food")
    checkEqual(turnZero.layHome, DefaultLayHome, "turn 0 default lay_home")
    var previous = defaultDoctrine()
    previous.scouts = 11
    previous.trailGain = 77
    let turnSeven = parsed("{\"poach\": 5}", previous, true)
    checkEqual(turnSeven.scouts, 11, "a missing field keeps last turn's value")
    checkEqual(turnSeven.trailGain, 77, "…for every integer field")
    checkEqual(turnSeven.poach, 5, "…and the one that was sent is used")
    report("missing fields fall back to the previous turn, then the default")

  block recallShapes:
    check(parsed("{\"recall\": \"true\"}").recall, "recall as a string")
    check(parsed("{\"recall\": 1}").recall, "recall as 1")
    check(not parsed("{\"recall\": \"false\"}").recall, "recall false string")
    check(not parsed("{\"recall\": 0}").recall, "recall as 0")
    var previous = defaultDoctrine()
    previous.recall = true
    check(not parsed("{\"recall\": true}", previous, true).recall,
      "recall may not run two turns in a row")
    report("recall accepts every documented shape and never repeats")

  block runeTruncation:
    let long = repeat("x", 400)
    let note = parsed("{\"note\": \"" & long & "\"}").note
    checkEqual(note.runeLen, MaxNoteRunes, "a 400-character note cuts to 140")

    ## A `say` whose 32nd and 33rd runes are a 4-byte emoji: the cut must land
    ## on the RUNE boundary, and the result must still round-trip through
    ## %* / $ / parseJson and be valid UTF-8.
    let say = repeat("a", 31) & "\u{1F41C}\u{1F41C}" & "tail"
    checkEqual(say.runeLen, 37, "the fixture is 37 runes")
    let cut = parsed("{\"say\": \"" & say & "\"}").say
    checkEqual(cut.runeLen, MaxSayRunes, "say cuts to exactly 32 runes")
    checkEqual(cut, repeat("a", 31) & "\u{1F41C}",
      "the cut lands on the rune boundary, keeping the whole emoji")
    checkEqual(validateUtf8(cut), -1, "the truncated say is valid UTF-8")
    var doctrine = defaultDoctrine()
    doctrine.say = cut
    doctrine.note = note
    let round = parseJson($doctrine.toJson())
    checkEqual(round["say"].getStr(), cut, "the truncated say round-trips")
    checkEqual(validateUtf8($doctrine.toJson()), -1,
      "the encoded doctrine is valid UTF-8")
    report("truncation lands on rune boundaries and round-trips as UTF-8")

  block unrecoverable:
    var raised = false
    try:
      discard parsed("I would rather not answer this one.")
    except HiveError:
      raised = true
    check(raised, "a reply with no JSON object at all raises")
    raised = false
    try:
      discard parsed("{\"weather\": \"sunny\"}")
    except HiveError:
      raised = true
    check(raised, "an object with no recognised doctrine key raises")
    report("only an unrecoverable reply raises, which is what triggers retry")

  block retryThenFallback:
    ## The engine contract: attempt 1 fails, exactly one retry, then the
    ## marcher doctrine plus a `fallback` event. `tests/test_engine.nim` runs
    ## it end to end against a fake transport; here we pin the shape of the
    ## fallback itself.
    var memory: BaselineMemory
    let view = %*{"turn": 0, "you": {"nest_block": [2, 1],
      "delivered_last_turn": 0, "last_doctrine": newJNull()},
      "sources": newJArray()}
    let fallback = scriptedResolved(view, skMarcher, 0, memory, dsFallback)
    checkEqual($fallback.source, "fallback", "the fallback is labelled")
    check(fallback.doctrine.isLegal(), "the fallback doctrine is legal")
    report("two consecutive failures land on a legal marcher doctrine")

main()
echo "test_doctrine: all checks passed"
