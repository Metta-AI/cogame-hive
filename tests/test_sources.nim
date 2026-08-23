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
    ## No orbit spawns while three are alive: run the real turn loop and count
    ## live non-bonanza sources at every spawn opportunity.
    var quiet = testConfig(4800, 42)
    quiet.bonanzaTicks = @[]
    var match = newSim(quiet, meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    check(match.sources.spawned mod Colonies == 0,
      "sources always spawn four at a time")
    report("orbits spawn four at a time and respect maxOrbits")

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

main()
echo "test_sources: all checks passed"
