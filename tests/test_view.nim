## The observation contract: what a seat can see, what it cannot, and the
## two-name-space assertion run over a whole scripted episode.

import std/[json, strutils]
import support/helpers
import hive/[pheromones, llm]

proc main() =
  let meadow = testField()

  block rivalOnlyWhereYouWalked:
    var match = newSim(testConfig(960, 42), meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    ## Re-run to a mid-turn state so `sensed` has content for this turn.
    var mid = newSim(testConfig(960, 42), meadow)
    let provide = scriptedProvider(allMarcher())
    while mid.tick < 600:
      if mid.tick mod mid.config.turnTicks == 0:
        mid.installDoctrines(provide(mid, mid.tick div mid.config.turnTicks))
      mid.stepTick()
    for seat in 0 ..< Colonies:
      let colony = mid.seatNest[seat]
      let view = buildView(mid, seat)
      let rival = view["trails"]["rival"]
      checkEqual(rival.len, BlockRows, "eleven rival rows")
      var digits = 0
      var dots = 0
      for by in 0 ..< BlockRows:
        let row = rival[by].getStr()
        checkEqual(row.len, BlockCols, "twenty rival columns")
        for bx in 0 ..< BlockCols:
          let index = by * BlockCols + bx
          let sensed = mid.sensed[colony][index] >= mid.turn - 1
          if sensed:
            check(row[bx] in {'0' .. '9'},
              "a sensed block carries a digit at (" & $bx & "," & $by & ")")
            inc digits
          else:
            checkEqual(row[bx], '.',
              "an unsensed block reads '.' at (" & $bx & "," & $by & ")")
            inc dots
      check(digits > 0, "seat " & $seat & " sensed at least one block")
      check(dots > 0, "seat " & $seat & " is blind somewhere")
    report("trails.rival shows a digit only where your own ants walked")

  block viewClockIsCurrent:
    ## The view handed to a policy for turn N must read `"turn": N` - not
    ## N-1 - and `delivered_last_turn` must be the deliveries of turn N-1,
    ## not of turn N-2. The marcher reads it as a fuel gauge and champion #1's
    ## prompt says to watch it, so a two-turn lag is a real misread.
    var match = newSim(testConfig(1440, 42), meadow)
    var seenTurns: seq[int]
    var seenTicks: seq[int]
    var gauge: seq[int]
    var runningTotal: seq[int]
    let inner = scriptedProvider(allMarcher())
    let recording = proc (m: Sim, turn: int):
        array[Colonies, ResolvedDoctrine] {.closure.} =
      let view = buildView(m, 0)
      seenTurns.add(view["turn"].getInt())
      seenTicks.add(view["tick"].getInt())
      gauge.add(view["you"]["delivered_last_turn"].getInt())
      runningTotal.add(m.delivered[m.seatNest[0]])
      inner(m, turn)
    match.runEpisode(recording)
    check(seenTurns.len >= 6, "the episode really ran several turns")
    for index, turn in seenTurns:
      checkEqual(turn, index, "the view for turn " & $index & " says turn " &
        $index)
      checkEqual(seenTicks[index], index * match.config.turnTicks,
        "...and carries its own tick")
    checkEqual(gauge[0], 0, "nothing was delivered before turn 0")
    for index in 1 ..< seenTurns.len:
      checkEqual(gauge[index], runningTotal[index] - runningTotal[index - 1],
        "delivered_last_turn at turn " & $index &
        " is the PREVIOUS turn's deliveries")
    check(gauge[^1] > 0, "...and the gauge is not vacuously zero")
    report("the view's turn number and fuel gauge are one turn fresh")

  block sourcesAreLastSeen:
    var match = newSim(testConfig(1440, 7), meadow)
    let provide = scriptedProvider(allMarcher())
    while match.tick < 1200:
      if match.tick mod match.config.turnTicks == 0:
        match.installDoctrines(provide(match,
          match.tick div match.config.turnTicks))
      match.stepTick()
    var checkedStale = false
    for seat in 0 ..< Colonies:
      let colony = match.seatNest[seat]
      let view = buildView(match, seat)
      for entry in view["sources"]:
        let id = entry["id"].getInt()
        check(match.seenTurn[colony][id] >= 0,
          "the view never lists a source this colony has not seen")
        checkEqual(entry["amount_seen"].getInt(),
          match.seenAmount[colony][id],
          "amount_seen is the value at the last sighting")
        checkEqual(entry["seen_turn"].getInt(), match.seenTurn[colony][id],
          "seen_turn is the turn of the last sighting")
        if entry["amount_seen"].getInt() != int(match.sources.items[id].amount):
          checkedStale = true
      ## Every source this colony HAS seen is listed.
      for id in 0 ..< match.sources.items.len:
        if id < match.seenTurn[colony].len and match.seenTurn[colony][id] >= 0:
          var found = false
          for entry in view["sources"]:
            if entry["id"].getInt() == id: found = true
          check(found, "a seen source is listed")
    check(checkedStale,
      "at least one listed amount_seen is stale, proving it is not live")
    report("sources[] is discovery-gated and reports last-seen amounts")

  block scoreboardIsPublic:
    var match = newSim(testConfig(480, 3), meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    for seat in 0 ..< Colonies:
      let view = buildView(match, seat)
      let board = view["scoreboard"]
      checkEqual(board.len, Colonies, "the scoreboard is complete")
      for row in board:
        check(row.hasKey("colony") and row.hasKey("delivered"),
          "every scoreboard row names a colony and its counter")
        var found = false
        for colony in 0 ..< Colonies:
          if meadow.nests[colony].alias == row["colony"].getStr():
            found = true
            checkEqual(row["delivered"].getInt(), match.delivered[colony],
              "the public counter is the real counter")
        check(found, "the scoreboard names only aliases")
      check(view.hasKey("field") and view["field"].hasKey("rock"),
        "the full static rock map is always visible")
      check(view["you"].hasKey("delivered_last_turn"), "the fuel gauge is there")
      check(not view.hasKey("ants"), "no god's-eye per-ant readout")
      check(not view["you"].hasKey("positions"), "no own-ant positions either")
    report("the scoreboard is public and complete for every seat")

  block twoNameSpaces:
    ## Run a whole scripted episode and assert no real player name appears in
    ## ANY view, event body or prompt.
    var config = testConfig(960, 42)
    config.players = @[
      PlayerConfig(name: "daveey"), PlayerConfig(name: "daveey-1"),
      PlayerConfig(name: "Baseline (1)"), PlayerConfig(name: "Baseline (2)")
    ]
    var match = newSim(config, meadow)
    var seenViews: seq[string]
    let provide = scriptedProvider(allMarcher())
    let recording = proc (m: Sim, turn: int):
        array[Colonies, ResolvedDoctrine] {.closure.} =
      for seat in 0 ..< Colonies:
        seenViews.add($buildView(m, seat))
        seenViews.add(userMessage(m, seat, "raid the centre"))
      provide(m, turn)
    match.runEpisode(recording)
    match.endMatch(erComplete, euFullTime)
    var turnsLlm, fallbackTurns: array[Colonies, int]
    var causes: array[Colonies, array[5, int]]
    let names = @["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
    let results = resultsJson(match, names,
      @["llm", "llm", "scripted", "scripted"], turnsLlm, fallbackTurns, causes)
    checkEqual(results["names"].len, Colonies, "results carry the real names")
    check(seenViews.len > 0, "views were actually recorded")
    for name in names:
      for text in seenViews:
        check(name notin text,
          "the real name '" & name & "' must never reach a view or a prompt")
      for event in match.events.items:
        check(name notin $event,
          "the real name '" & name & "' must never reach an event body")
    ## And the aliases DO appear, so the assertion is not vacuous.
    var sawAlias = false
    for text in seenViews:
      if "Amber" in text: sawAlias = true
    check(sawAlias, "the colony aliases do appear in the views")
    check("Amber" in $results["aliases"], "results carry the aliases too")
    report("no real player name reaches any view, event body or prompt")

  block permutationIsSeeded:
    ## The seat -> nest permutation is re-drawn every episode from the seed,
    ## which is the per-episode anonymisation.
    var seen: seq[array[Colonies, int]]
    for seed in 1 .. 40:
      let match = newSim(testConfig(240, seed), meadow)
      if match.seatNest notin seen:
        seen.add(match.seatNest)
    check(seen.len >= 4,
      "the seat -> nest permutation actually varies with the seed (" &
      $seen.len & " distinct in 40 seeds)")
    let a = newSim(testConfig(240, 99), meadow)
    let b = newSim(testConfig(240, 99), meadow)
    checkEqual(a.seatNest, b.seatNest, "the same seed gives the same seating")
    report("the seat -> nest permutation is seeded and varies")

main()
echo "test_view: all checks passed"
