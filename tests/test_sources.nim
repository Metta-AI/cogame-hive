## Food: symmetric orbits, the two centre bonanzas, depletion, expiry, the
## rejection loop and the 24-tick harvest buckets.

import std/[algorithm, json]
import support/helpers
import hive/[sources, field]

proc main() =
  let meadow = testField()

  block orbitIsSymmetric:
    var set = initSourceSet(meadow.cols, meadow.rows)
    var rng = initPcg(1234)
    for trial in 0 ..< 200:
      let cells = drawOrbitCells(set, meadow, rng, 14)
      check(cells.len == Colonies, "an orbit is exactly four cells")
      let base = cells[0]
      checkEqual(cells[1], (cx: meadow.cols - 1 - base.cx, cy: base.cy),
        "the second cell mirrors in x")
      checkEqual(cells[2], (cx: base.cx, cy: meadow.rows - 1 - base.cy),
        "the third cell mirrors in y")
      checkEqual(cells[3],
        (cx: meadow.cols - 1 - base.cx, cy: meadow.rows - 1 - base.cy),
        "the fourth cell mirrors in both")
      for cell in cells:
        check(meadow.isFree(cell.cx, cell.cy), "a drawn cell is never rock")
        for nest in 0 ..< Colonies:
          check(chebyshev(cell.cx, cell.cy, meadow.nests[nest].cx,
            meadow.nests[nest].cy) >= 14,
            "a drawn cell is never within 14 of a nest centre")
      check(base.cx >= meadow.spawnQuadrant[0] and
        base.cx <= meadow.spawnQuadrant[2] and
        base.cy >= meadow.spawnQuadrant[1] and
        base.cy <= meadow.spawnQuadrant[3],
        "the base cell is drawn inside the top-left quadrant")
    report("an orbit is four mirror-symmetric, legal cells")

  block clearanceFromLiveSources:
    var set = initSourceSet(meadow.cols, meadow.rows)
    var rng = initPcg(77)
    for round in 0 ..< 12:
      let cells = drawOrbitCells(set, meadow, rng, 14)
      if cells.len == 0:
        continue
      for cell in cells:
        for item in set.items:
          if item.alive:
            check(chebyshev(cell.cx, cell.cy, int(item.cx), int(item.cy)) >= 3,
              "a drawn cell is never within 3 of a live source")
        discard set.addSource(meadow, cell.cx, cell.cy, 60, 0, 1440, false)
    report("the rejection loop keeps 3 cells of clearance and terminates")

  block orbitCap:
    ## No orbit spawns while maxOrbits are already alive. Run the real turn
    ## loop and check the invariant at every spawn opportunity, before and
    ## after the spawn.
    var quiet = testConfig(4800, 42)
    quiet.bonanzaTicks = @[]
    var match = newSim(quiet, meadow)
    let provide = scriptedProvider(allMarcher())
    var spawnsWhileFull = 0
    while not match.finished:
      if match.tick mod match.config.turnTicks == 0:
        match.beginTurn()
        match.installDoctrines(provide(match, match.turn))
      if match.tick mod match.config.sourceSpawnPeriod == 0:
        let before = match.sources.orbitsAlive()
        let spawnedBefore = match.sources.spawned
        check(before <= match.config.maxOrbits,
          "orbits alive (" & $before & ") never exceeds maxOrbits")
        match.stepTick()
        let spawnedNow = match.sources.spawned - spawnedBefore
        if before >= match.config.maxOrbits and spawnedNow > 0:
          inc spawnsWhileFull
      else:
        match.stepTick()
      if match.tick >= match.config.episodeTicks:
        match.endMatch(erComplete, euFullTime)
    check(match.sources.spawned mod Colonies == 0,
      "sources always spawn four at a time")
    checkEqual(spawnsWhileFull, 0,
      "no orbit ever spawned while maxOrbits were already alive")
    report("no orbit spawns while maxOrbits are alive")

  block aPartlyEatenOrbitHoldsItsSlot:
    ## The rule the old ceil(live / 4) count got wrong. Three orbits with one
    ## survivor each is THREE orbits alive, not (3 + 3) div 4 = 1, so no
    ## fourth orbit may spawn. Row 44 of the meadow is entirely free floor.
    var set = initSourceSet(meadow.cols, meadow.rows)
    var indices: seq[int]
    for orbit in 0 .. 2:
      for member in 0 .. 3:
        let cx = 40 + orbit * 4 + member
        check(meadow.isFree(cx, 44), "the probe cell is free floor")
        indices.add(set.addSource(meadow, cx, 44, 60, orbit * 240, 1440, false))
    checkEqual(set.orbitsAlive(), 3, "three whole orbits are three orbits")
    for orbit in 0 .. 2:
      for member in 1 .. 3:
        set.retire(meadow, indices[orbit * 4 + member])
    checkEqual(set.liveCount(), 3, "one survivor left in each orbit")
    checkEqual(set.orbitsAlive(), 3,
      "three orbits with one survivor each are still THREE orbits alive")
    set.retire(meadow, indices[0])
    checkEqual(set.orbitsAlive(), 2, "killing an orbit outright frees a slot")
    ## A bonanza is not an orbit and never occupies a slot.
    discard set.addSource(meadow, 79, 43, 100, 1200, 900, true)
    discard set.addSource(meadow, 80, 43, 100, 1200, 900, true)
    checkEqual(set.orbitsAlive(), 2, "bonanzas do not count as orbits")
    report("an orbit is alive while ANY of its four members is")

  block bonanzas:
    var config = testConfig(4800, 42)
    config.maxOrbits = 0
    config.bonanzaTicks = @[1200, 3600]
    var match = newSim(config, meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    checkEqual(match.sources.spawned, 8,
      "the two bonanzas spawn four sources each and nothing else does")
    var seenTicks: seq[int]
    for item in match.sources.items:
      check(item.bonanza, "every source is a bonanza source")
      checkEqual(int(item.spawnAmount), config.bonanzaAmount,
        "a bonanza source carries bonanzaAmount")
      if int(item.spawnTick) notin seenTicks:
        seenTicks.add(int(item.spawnTick))
    seenTicks.sort()
    checkEqual(seenTicks, @[1200, 3600], "the bonanzas land at 1200 and 3600")
    var cells: seq[tuple[cx, cy: int]]
    for index in 0 ..< 4:
      cells.add((cx: int(match.sources.items[index].cx),
        cy: int(match.sources.items[index].cy)))
    checkEqual(cells, meadow.bonanzaCells,
      "the first bonanza lands on the four centre cells")
    report("the two bonanzas land on the centre block at 1200 and 3600")

  block depletionAndExpiry:
    var set = initSourceSet(meadow.cols, meadow.rows)
    let index = set.addSource(meadow, 60, 30, 2, 0, 48, false)
    checkEqual(set.liveCount(), 1, "a fresh source is alive")
    check(set.foodNear[30 * meadow.cols + 60] > 0'i16,
      "a live source with food is smellable")
    set.takeUnit(meadow, index, 0)
    set.takeUnit(meadow, index, 1)
    checkEqual(int(set.items[index].amount), 0, "two units taken")
    checkEqual(set.foodNear[30 * meadow.cols + 60], 0'i16,
      "an emptied source stops being smellable immediately")
    checkEqual(set.buckets.len, 2, "one harvest bucket per (source, colony)")
    var units = 0
    for bucket in set.buckets:
      units += int(bucket.units)
    checkEqual(units, 2, "the buckets sum to the units removed")
    set.retire(meadow, index)
    checkEqual(set.liveCount(), 0, "a retired source is not live")
    report("a source depletes at zero and its scent clears at once")

  block harvestFlush:
    ## Over a whole episode the harvest events sum to the units removed.
    var config = testConfig(2880, 3)
    var match = newSim(config, meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    var harvested = 0
    for event in match.events.items:
      if event{"type"}.getStr() == "harvest":
        harvested += event{"u"}.getInt()
    var removed = 0
    for colony in 0 ..< Colonies:
      removed += match.harvested[colony]
    checkEqual(harvested, removed,
      "the flushed harvest records sum to total units removed")
    check(harvested > 0, "the episode actually harvested something")
    checkEqual(match.sources.buckets.len, 0, "the buckets are empty at the end")
    var gone = 0
    var causes: seq[string]
    for event in match.events.items:
      if event{"type"}.getStr() == "source_gone":
        inc gone
        let cause = event{"cause"}.getStr()
        if cause notin causes: causes.add(cause)
    check(gone > 0, "sources retire over an episode")
    for cause in causes:
      check(cause == "depleted" or cause == "expired",
        "source_gone carries a legal cause, got " & cause)
    report("harvest buckets flush every 24 ticks and sum exactly")

  block raidRadiusNamesTheRivalNotTheNearest:
    ## A delivery is a raid when the source cell was inside a DIFFERENT
    ## colony's raidRadius. Consulting the NEAREST nest instead answers a
    ## different question: if your own nest happens to be marginally closer,
    ## the cell is still inside the rival's radius and the food still came
    ## off their doorstep.
    let mine = meadow.nests[0]
    checkEqual(nearestNest(meadow, mine.cx + 1, mine.cy, 20), 0,
      "a cell beside your own nest is inside your own radius")
    checkEqual(nearestNest(meadow, mine.cx + 1, mine.cy, 20, exclude = 0), -1,
      "...and inside nobody else's, so it is never a raid")
    ## Nest 2 sits 63 cells below nest 0. A cell 30 below nest 0 is 33 from
    ## nest 2: inside a 40-cell radius of BOTH, and nearer to nest 0.
    let probeY = mine.cy + 30
    checkEqual(chebyshev(mine.cx, probeY, mine.cx, mine.cy), 30, "30 from home")
    checkEqual(chebyshev(mine.cx, probeY, meadow.nests[2].cx,
      meadow.nests[2].cy), 33, "33 from the rival")
    checkEqual(nearestNest(meadow, mine.cx, probeY, 40), 0,
      "the NEAREST nest within 40 is your own")
    checkEqual(nearestNest(meadow, mine.cx, probeY, 40, exclude = 0), 2,
      "excluding your own names the rival whose radius the cell sits in")
    report("the raid rule asks which RIVAL radius the cell is in")

main()
echo "test_sources: all checks passed"
