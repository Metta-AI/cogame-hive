## The whole episode has to fit inside the wall-clock budget with room to
## spare: 4800 ticks, 96 ants and the full 220 KiB field in under 45 s in a
## release build, and one turn snapshot round-trip under 5 ms.

import std/[monotimes, times]
import support/helpers

## The design note's bounds are stated for a RELEASE build, which is what the
## container ships and what the hosted episode runs. `ci.yml` runs every test
## twice, so the debug pass gets a proportionate allowance rather than a
## deleted assertion - a debug build of this sim measures ~6x slower.
const
  EpisodeBudgetSeconds = when defined(release): 45.0 else: 270.0
  SnapshotBudgetMs = when defined(release): 5.0 else: 30.0

proc main() =
  let meadow = testField()

  block fullEpisode:
    let started = getMonoTime()
    var match = newSim(testConfig(4800, 42), meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    let elapsed = (getMonoTime() - started).inMilliseconds.float / 1000.0
    checkEqual(match.tick, 4800, "the whole episode ran")
    checkEqual(match.keyframes.len, 200, "200 keyframes")
    check(elapsed < EpisodeBudgetSeconds,
      "4800 ticks with 96 ants completed in " & $elapsed &
      "s, budget " & $EpisodeBudgetSeconds & "s")
    report("a full 4800-tick episode takes " &
      $(elapsed * 1000).int & " ms (budget " &
      $(EpisodeBudgetSeconds * 1000).int & " ms)")

  block snapshotRoundTrip:
    var match = newSim(testConfig(960, 42), meadow)
    match.runEpisode(scriptedProvider(allMarcher()))
    check(match.snapshots.len > 0, "snapshots were taken")
    var probe = newSim(testConfig(960, 42), meadow)
    let rounds = 20
    let started = getMonoTime()
    for round in 0 ..< rounds:
      let snapshot = match.snapshots[round mod match.snapshots.len]
      probe.restoreSnapshot(snapshot)
      discard probe.takeSnapshot()
    let perRound = (getMonoTime() - started).inMicroseconds.float /
      (rounds.float * 1000.0)
    check(perRound < SnapshotBudgetMs,
      "a snapshot round-trip took " & $perRound & " ms, budget " &
      $SnapshotBudgetMs & " ms")
    report("a turn snapshot round-trip costs " & $perRound & " ms")

main()
echo "test_perf: all checks passed"
