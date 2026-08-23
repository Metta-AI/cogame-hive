## The formula and its sign. Share of all food returned, higher is better,
## and the four printed numbers sum to exactly 1.0 for every legal outcome.

import std/[json, math]
import support/helpers

proc simWith(delivered: array[Colonies, int], seed = 42): Sim =
  ## A match whose counters are set directly. `delivered` is indexed by SLOT,
  ## so it is written through the seat -> nest permutation.
  result = newSim(testConfig(240, seed), testField())
  for seat in 0 ..< Colonies:
    result.delivered[result.seatNest[seat]] = delivered[seat]

proc main() =
  block workedExample:
    let match = simWith([412, 366, 289, 233])
    let scored = match.scores()
    checkEqual(match.totalDelivered(), 1300, "total")
    check(abs(scored[0] - 0.31692) < 0.00001, "score 0 is 0.31692")
    check(abs(scored[1] - 0.28154) < 0.00001, "score 1 is 0.28154")
    check(abs(scored[2] - 0.22231) < 0.00001, "score 2 is 0.22231")
    check(abs(scored[3] - 0.17923) < 0.00001, "score 3 is 0.17923")
    checkEqual(match.winnerSlot(), 0, "slot 0 wins the worked example")
    report("the worked example [412,366,289,233] scores as documented")

  block sumIsExactlyOne:
    var rng = initPcg(2026)
    for trial in 0 ..< 500:
      var delivered: array[Colonies, int]
      for seat in 0 ..< Colonies:
        delivered[seat] = rng.rnd(4000)
      let match = simWith(delivered, 100 + trial)
      let scored = match.scores()
      var total = 0.0
      for value in scored:
        check(value >= 0.0 and value <= 1.0, "every share is in [0,1]")
        total += value
      checkEqual(total, 1.0,
        "the four printed shares sum to EXACTLY 1.0 on trial " & $trial)
    report("sum(scores) == 1.0 exactly over 500 randomised delivery vectors")

  block nobodyScored:
    let match = simWith([0, 0, 0, 0])
    let scored = match.scores()
    for seat in 0 ..< Colonies:
      checkEqual(scored[seat], 0.25, "an empty match scores 0.25 everywhere")
    checkEqual(match.winnerSlot(), -1, "an empty match has no winner")
    report("total == 0 gives four 0.25s and winner null")

  block tiedMaximum:
    let match = simWith([50, 50, 10, 3])
    checkEqual(match.winnerSlot(), -1, "a tied maximum has no winner")
    match.endMatch(erComplete, euFullTime)
    var turnsLlm, fallbackTurns: array[Colonies, int]
    var causes: array[Colonies, array[5, int]]
    let results = resultsJson(match, @["a", "b", "c", "d"],
      @["scripted", "scripted", "scripted", "scripted"], turnsLlm,
      fallbackTurns, causes)
    for seat in 0 ..< Colonies:
      checkEqual(results["win"][seat].getBool(), false,
        "a tied maximum gives win all false")
    checkEqual(results["winner"].kind, JNull, "winner is null on a tie")
    report("a tied maximum gives win all false and winner null")

  block monotone:
    var rng = initPcg(9)
    for trial in 0 ..< 200:
      var delivered: array[Colonies, int]
      for seat in 0 ..< Colonies:
        delivered[seat] = 1 + rng.rnd(500)
      let low = simWith(delivered, 300 + trial)
      var raised = delivered
      raised[0] += 1 + rng.rnd(50)
      let high = simWith(raised, 300 + trial)
      check(high.scores()[0] > low.scores()[0],
        "more delivered always means a higher score")
    report("higher delivered always means a higher score")

  block faultAndDeadline:
    let faulted = simWith([100, 20, 5, 1])
    faulted.endMatch(erFault, euSimFault)
    var turnsLlm, fallbackTurns: array[Colonies, int]
    var causes: array[Colonies, array[5, int]]
    let results = resultsJson(faulted, @["a", "b", "c", "d"],
      @["llm", "llm", "scripted", "scripted"], turnsLlm, fallbackTurns, causes)
    var total = 0.0
    for seat in 0 ..< Colonies:
      checkEqual(results["scores"][seat].getFloat(), 0.25,
        "a fault scores 0.25 for every seat")
      total += results["scores"][seat].getFloat()
    checkEqual(total, 1.0, "a fault still sums to 1.0")
    checkEqual(results["winner"].kind, JNull, "a fault has no winner")
    checkEqual(results["reason"].getStr(), "fault", "reason")
    checkEqual(results["end_rule"].getStr(), "sim_fault", "end_rule")

    ## A deadline cut mid-episode scores the counters as they stand.
    var config = testConfig(4800, 42)
    var cut = newSim(config, testField())
    var stopAt = 720
    let probe = proc (match: Sim, turn: int): bool {.closure.} =
      match.tick >= stopAt
    cut.runEpisode(scriptedProvider(allMarcher()), probe)
    checkEqual($cut.reason, "deadline", "the probe ends the match deadline")
    checkEqual($cut.rule, "wall_clock", "end_rule is wall_clock")
    check(cut.tick < 4800, "the sim stopped before full time")
    var deadlineTotal = 0.0
    for value in cut.scores():
      deadlineTotal += value
    checkEqual(deadlineTotal, 1.0, "a deadline cut still sums to 1.0")
    report("fault and deadline endings score legally and still sum to 1.0")

main()
echo "test_scoring: all checks passed"
