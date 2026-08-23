## THE GATE. Same seed + same resolved doctrine stream => the same digest at
## every keyframe. Twice in one process, once in a fresh instance, against a
## committed golden fixture, and with the turn snapshots proving they
## reproduce the forward run byte for byte.

import std/[json, os]
import support/helpers
import hive/[pheromones, sources]

proc digestsOf(match: Sim): seq[int] =
  for frame in match.keyframes:
    result.add(frame["d"].getBiggestInt())

proc fixedDoctrines(seed: int): DoctrineProvider =
  ## A doctrine stream that does not depend on the sim state, so a digest
  ## difference can only come from the step itself.
  var rng = initPcg(seed)
  var script: seq[array[Colonies, ResolvedDoctrine]]
  for turn in 0 ..< 64:
    var row: array[Colonies, ResolvedDoctrine]
    for seat in 0 ..< Colonies:
      row[seat] = ResolvedDoctrine(doctrine: Doctrine(
        scouts: rng.rnd(101), trailGain: rng.rnd(101), poach: rng.rnd(101),
        spread: rng.rnd(101), layFood: rng.rnd(101), layHome: rng.rnd(101),
        recall: false, hasFocus: turn mod 3 == 0,
        focusBx: rng.rnd(BlockCols), focusBy: rng.rnd(BlockRows),
        focusWeight: rng.rnd(101), note: "fixed", say: ""),
        source: dsScripted)
      if not row[seat].doctrine.hasFocus:
        row[seat].doctrine.focusWeight = 0
    script.add(row)
  result = proc (match: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
    script[turn mod script.len]

proc main() =
  let meadow = testField()

  block sameProcessTwice:
    var first = newSim(testConfig(4800, 42), meadow)
    first.runEpisode(fixedDoctrines(7))
    var second = newSim(testConfig(4800, 42), meadow)
    second.runEpisode(fixedDoctrines(7))
    checkEqual(digestsOf(second), digestsOf(first),
      "two runs in one process agree at every keyframe")
    checkEqual(second.antBytes, first.antBytes,
      "two runs in one process agree ant for ant")
    checkEqual(first.keyframes.len, 200, "a 4800-tick match has 200 keyframes")
    report("same seed + same doctrines => identical digests, twice in one process")

  block freshInstance:
    ## A fresh instance built through the ordinary constructor path, with the
    ## field re-parsed from disk, must still agree.
    var fresh = newSim(testConfig(4800, 42), testField())
    fresh.runEpisode(fixedDoctrines(7))
    var again = newSim(testConfig(4800, 42), meadow)
    again.runEpisode(fixedDoctrines(7))
    checkEqual(digestsOf(fresh), digestsOf(again),
      "a fresh instance agrees with the in-process run")
    report("a fresh instance reproduces the same digests")

  block oneUnitChangesEverything:
    ## Nudged on EVERY turn: `poach` and `lay_food` are physically inert on
    ## turn 0 (no rival paint within reach yet, and nobody is carrying), so a
    ## turn-0-only nudge would honestly not move the digest.
    var base = newSim(testConfig(2880, 42), meadow)
    base.runEpisode(fixedDoctrines(7))
    let baseline = digestsOf(base)[^1]
    var changed = 0
    for field in 0 .. 5:
      var nudged = newSim(testConfig(2880, 42), meadow)
      let inner = fixedDoctrines(7)
      let bumped = proc (match: Sim, turn: int):
          array[Colonies, ResolvedDoctrine] {.closure.} =
        result = inner(match, turn)
        block:
          case field
          of 0: result[0].doctrine.scouts =
            (result[0].doctrine.scouts + 1) mod 101
          of 1: result[0].doctrine.trailGain =
            (result[0].doctrine.trailGain + 1) mod 101
          of 2: result[0].doctrine.poach =
            (result[0].doctrine.poach + 1) mod 101
          of 3: result[0].doctrine.spread =
            (result[0].doctrine.spread + 1) mod 101
          of 4: result[0].doctrine.layFood =
            (result[0].doctrine.layFood + 1) mod 101
          else: result[0].doctrine.layHome =
            (result[0].doctrine.layHome + 1) mod 101
      nudged.runEpisode(bumped)
      if digestsOf(nudged)[^1] != baseline:
        inc changed
    checkEqual(changed, 6,
      "a one-unit change in ANY doctrine integer changes the final digest")
    report("a one-unit doctrine change changes the final digest")

  block goldenFixture:
    let golden = parseJson(readRepoFile("tests/fixtures/golden_digests.json"))
    checkEqual(golden["game_version"].getStr(), GameVersion,
      "the golden fixture was recorded for this GameVersion; bump and " &
      "re-record with tools/record_fixtures.nim in the SAME commit")
    var config = testConfig(golden["ticks"].getInt(), golden["seed"].getInt())
    var match = newSim(config, meadow)
    match.runEpisode(scriptedProvider(
      [skMarcher, skDriftling, skMarcher, skDriftling]))
    checkEqual(match.keyframes.len, golden["keyframes"].len,
      "the golden fixture pins every keyframe")
    for index, frame in match.keyframes:
      checkEqual(frame["t"].getInt(), golden["keyframes"][index]["t"].getInt(),
        "golden keyframe tick " & $index)
      checkEqual(frame["d"].getBiggestInt(),
        golden["keyframes"][index]["d"].getBiggestInt(),
        "golden keyframe digest at tick " & $frame["t"].getInt() &
        " (re-record with tools/record_fixtures.nim if the rules changed)")
    report("the committed golden digests still hold")

  block snapshots:
    ## The turn snapshots reproduce the state the forward run had at the same
    ## tick, byte for byte.
    var forward = newSim(testConfig(960, 42), meadow)
    var recorded: seq[tuple[tick: int, digest: uint32]]
    let inner = fixedDoctrines(7)
    while not forward.finished:
      if forward.tick mod forward.config.turnTicks == 0:
        forward.installDoctrines(inner(forward,
          forward.tick div forward.config.turnTicks))
        recorded.add((tick: forward.tick, digest: forward.hiveStateDigest()))
      forward.stepTick()
      if forward.tick >= forward.config.episodeTicks:
        forward.endMatch(erComplete, euFullTime)
    checkEqual(forward.snapshots.len, recorded.len,
      "one snapshot per turn")
    for index, entry in recorded:
      let snapshot = forward.snapshots[index]
      checkEqual(snapshot.tick, entry.tick, "snapshot " & $index & " tick")
      var probe = newSim(testConfig(960, 42), meadow)
      probe.restoreSnapshot(snapshot)
      checkEqual(probe.hiveStateDigest(), entry.digest,
        "snapshot " & $index & " restores the forward state exactly")
      checkEqual(probe.planes.cells[0][PlaneFood],
        snapshot.planes.cells[0][PlaneFood], "planes restore byte for byte")
      checkEqual(probe.sources.items.len, snapshot.sources.items.len,
        "sources restore")
    report("every turn snapshot reproduces the forward state byte for byte")

main()
echo "test_determinism: all checks passed"
