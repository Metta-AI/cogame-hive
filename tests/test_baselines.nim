## The bounded-orders / legality assertion on the scripted baselines: whatever
## view you hand them, the emitted doctrine validates against the schema AND
## its compiled coefficients land inside their stated ranges. Plus the ladder
## assertion: the marcher out-delivers the driftling.

import std/[json, strutils, unicode]
import support/helpers

proc randomView(rng: var Pcg, turn: int): JsonNode =
  ## A deliberately hostile view: absurd amounts, out-of-range blocks, missing
  ## keys, and a last_doctrine that is sometimes null.
  var sources = newJArray()
  for index in 0 ..< rng.rnd(6):
    sources.add(%*{
      "id": index,
      "block": [rng.rnd(40) - 10, rng.rnd(30) - 10],
      "cell": [rng.rnd(200), rng.rnd(120)],
      "amount_seen": rng.rnd(400) - 100,
      "seen_turn": rng.rnd(turn + 1),
      "near_nest": newJNull()
    })
  result = %*{
    "turn": turn,
    "you": {
      "nest_block": [rng.rnd(BlockCols), rng.rnd(BlockRows)],
      "delivered": rng.rnd(500),
      "delivered_last_turn": (if rng.rnd(3) == 0: 0 else: rng.rnd(60)),
      "last_doctrine":
        (if rng.rnd(2) == 0: newJNull()
         else: %*{"focus": (if rng.rnd(2) == 0: newJNull()
                            else: %[rng.rnd(BlockCols), rng.rnd(BlockRows)])})
    },
    "sources": sources
  }
  if rng.rnd(7) == 0:
    result["you"].delete("nest_block")
  if rng.rnd(9) == 0:
    result.delete("sources")

proc main() =
  block legality:
    var rng = initPcg(31337)
    for kind in [skMarcher, skDriftling]:
      var memory: BaselineMemory
      var previousRecall = false
      for trial in 0 ..< 500:
        let turn = trial mod 20
        let doctrine = scriptedDoctrine(randomView(rng, turn), kind, turn,
          memory)
        check(doctrine.isLegal(),
          $kind & " emitted an illegal doctrine on trial " & $trial)
        check(doctrine.scouts in 0 .. 100, "scouts in range")
        check(doctrine.trailGain in 0 .. 100, "trail_gain in range")
        check(doctrine.poach in 0 .. 100, "poach in range")
        check(doctrine.spread in 0 .. 100, "spread in range")
        check(doctrine.layFood in 0 .. 100, "lay_food in range")
        check(doctrine.layHome in 0 .. 100, "lay_home in range")
        if doctrine.hasFocus:
          check(doctrine.focusBx in 0 ..< BlockCols, "focus bx in range")
          check(doctrine.focusBy in 0 ..< BlockRows, "focus by in range")
        else:
          checkEqual(doctrine.focusWeight, 0,
            "focus_weight is 0 when focus is null")
        check(doctrine.note.runeLen <= MaxNoteRunes, "note <= 140 runes")
        check(doctrine.say.runeLen <= MaxSayRunes, "say <= 32 runes")
        check(not (doctrine.recall and previousRecall),
          "recall never runs two turns in a row")
        previousRecall = doctrine.recall

        let c = coefficients(doctrine, 24)
        check(c.alphaFood in 0 .. 400, "alphaFood 0..400")
        check(c.alphaRival in 0 .. 300, "alphaRival 0..300")
        check(c.alphaHome in 0 .. 300, "alphaHome 0..300")
        check(c.alphaFwd in 120 .. 320, "alphaFwd 120..320")
        check(c.alphaNoise in 40 .. 440, "alphaNoise 40..440")
        check(c.betaHome in 200 .. 400, "betaHome 200..400")
        check(c.layFood in 40 .. 340, "layFood 40..340")
        check(c.layHome in 20 .. 220, "layHome 20..220")
        check(c.scoutCount in 0 .. 24, "scoutCount 0..24")
    report("500 random views x 2 baselines: every doctrine legal, every " &
      "coefficient in range")

  block coefficientEdges:
    var lowDoctrine = defaultDoctrine()
    lowDoctrine.scouts = 0
    lowDoctrine.trailGain = 0
    lowDoctrine.poach = 0
    lowDoctrine.spread = 0
    lowDoctrine.layFood = 0
    lowDoctrine.layHome = 0
    let low = coefficients(lowDoctrine, 24)
    checkEqual(low.alphaFood, 0, "alphaFood floor")
    checkEqual(low.alphaFwd, 320, "alphaFwd at spread 0")
    checkEqual(low.alphaNoise, 440, "alphaNoise at trail_gain 0")
    checkEqual(low.betaHome, 200, "betaHome floor")
    checkEqual(low.layFood, 40, "layFood floor")
    checkEqual(low.layHome, 20, "layHome floor")
    checkEqual(low.scoutCount, 0, "scoutCount floor")
    var highDoctrine = defaultDoctrine()
    highDoctrine.scouts = 100
    highDoctrine.trailGain = 100
    highDoctrine.poach = 100
    highDoctrine.spread = 100
    highDoctrine.layFood = 100
    highDoctrine.layHome = 100
    let high = coefficients(highDoctrine, 24)
    checkEqual(high.alphaFood, 400, "alphaFood ceiling")
    checkEqual(high.alphaRival, 300, "alphaRival ceiling")
    checkEqual(high.alphaHome, 300, "alphaHome ceiling")
    checkEqual(high.alphaFwd, 120, "alphaFwd at spread 100")
    checkEqual(high.alphaNoise, 40, "alphaNoise at trail_gain 100")
    checkEqual(high.betaHome, 400, "betaHome ceiling")
    checkEqual(high.layFood, 340, "layFood ceiling")
    checkEqual(high.layHome, 220, "layHome ceiling")
    checkEqual(high.scoutCount, 24, "scoutCount ceiling")
    report("the coefficient table hits its documented endpoints exactly")

  block scriptKindParsing:
    checkEqual(parseScriptKind("marcher"), skMarcher, "marcher")
    checkEqual(parseScriptKind("1"), skMarcher, "1 means marcher")
    checkEqual(parseScriptKind("TRUE"), skMarcher, "true means marcher")
    checkEqual(parseScriptKind("yes"), skMarcher, "yes means marcher")
    checkEqual(parseScriptKind("driftling"), skDriftling, "driftling")
    checkEqual(parseScriptKind(""), skNone, "empty means none")
    checkEqual(parseScriptKind("nonsense"), skNone, "anything else is none")
    report("PLAYER_SCRIPTED parsing follows the documented table")

  block ladderSpread:
    ## Two marcher seats against two driftling seats at seed 42: the match
    ## completes and the marchers out-deliver the driftlings, so the ladder
    ## has a spread.
    let match = runScripted(4800, 42, [skMarcher, skDriftling, skMarcher,
      skDriftling])
    checkEqual($match.reason, "complete", "the baseline match completes")
    checkEqual($match.rule, "full_time", "on full time")
    checkEqual(match.tick, 4800, "the whole episode ran")
    var marcher = 0
    var driftling = 0
    for seat in 0 ..< Colonies:
      let delivered = match.delivered[match.seatNest[seat]]
      if seat mod 2 == 0: marcher += delivered else: driftling += delivered
    check(match.totalDelivered() > 0, "food was actually returned")
    check(marcher > driftling,
      "the marcher seats out-deliver the driftling seats (" & $marcher &
      " vs " & $driftling & ")")
    report("marcher beats driftling at seed 42: " & $marcher & " vs " &
      $driftling)

  block gridHarnessIsCommitted:
    ## Acceptance checklist item 7: the baseline's parameters were tuned with
    ## a grid harness, not guessed. The harness is tools/tune_marcher.nim and
    ## ci.yml's `test` job runs it in release on every push; this asserts it
    ## exists, that it sweeps the shipped configuration rather than a copy of
    ## it, and that it is actually wired into CI.
    let harness = readRepoFile("tools/tune_marcher.nim")
    check("ShippedMarcher" in harness,
      "the harness sweeps the SHIPPED parameters, not a private copy")
    check("scriptedResolved" in harness,
      "and it drives the real baseline code path")
    let workflow = readRepoFile(".github/workflows/ci.yml")
    check("tools/tune_marcher.nim" in workflow,
      "ci.yml runs the grid harness")
    ## The shipped pump doctrine is exactly ShippedMarcher, so the grid the
    ## harness sweeps is the grid these numbers came out of.
    var memory = BaselineMemory()
    let view = %*{
      "turn": 5,
      "you": {"nest_block": [2, 1], "delivered": 40,
              "delivered_last_turn": 9, "last_doctrine": newJNull()},
      "sources": [{"id": 0, "block": [9, 5], "cell": [76, 43],
                   "amount_seen": 40, "seen_turn": 3,
                   "near_nest": newJNull()}]
    }
    let pump = scriptedDoctrine(view, skMarcher, 5, memory)
    checkEqual(pump.scouts, ShippedMarcher.scouts, "pump scouts")
    checkEqual(pump.trailGain, ShippedMarcher.trailGain, "pump trail_gain")
    checkEqual(pump.poach, ShippedMarcher.poach, "pump poach")
    checkEqual(pump.spread, ShippedMarcher.spread, "pump spread")
    checkEqual(pump.layFood, ShippedMarcher.layFood, "pump lay_food")
    checkEqual(pump.layHome, ShippedMarcher.layHome, "pump lay_home")
    checkEqual(pump.focusWeight, ShippedMarcher.focusWeight,
      "pump focus_weight")
    report("the marcher's pump doctrine is the grid harness's ShippedMarcher")

main()
echo "test_baselines: all checks passed"
