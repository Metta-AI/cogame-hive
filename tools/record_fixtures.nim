## Records the committed test fixtures:
##
##   tests/fixtures/golden_digests.json  the keyframe digests for seed 42 over
##                                       960 ticks, so any rule change shows up
##                                       in the diff (bump GameVersion and
##                                       re-record in the SAME commit)
##   tests/fixtures/sample_replay.json   a full scripted episode's replay, used
##                                       by the node wasm smoke in CI
##
##   usage: nim r --path:src tools/record_fixtures.nim

import std/[json, os, unicode]
import hive/[types, config, field, sim, rules, broadcast, baselines, replay]

proc provider(kinds: array[Colonies, ScriptKind]): DoctrineProvider =
  var memory: array[Colonies, BaselineMemory]
  result = proc (match: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
    for seat in 0 ..< Colonies:
      result[seat] = scriptedResolved(buildView(match, seat), kinds[seat],
        turn, memory[seat])
      ## Force one non-ASCII `say` into the stream so the replay's UTF-8 path
      ## is real, not hypothetical.
      if turn == 1 and seat == 0:
        result[seat].doctrine.say = "road \u00e9\u00e8 \u{1F41C}"

proc fixtureConfig(ticks: int): GameConfig =
  result = defaultGameConfig()
  result.seed = 42
  result.episodeTicks = ticks
  result.bonanzaTicks = @[480]
  result.players = @[
    PlayerConfig(name: "daveey"), PlayerConfig(name: "daveey-1"),
    PlayerConfig(name: "Baseline (1)"), PlayerConfig(name: "Baseline (2)")
  ]
  result.tokens = @["t0", "t1", "t2", "t3"]

when isMainModule:
  let root = currentSourcePath().parentDir().parentDir()
  let meadow = parseFieldSpec(parseJson(
    readFile(root / "data" / "meadow.fieldspec.json")))
  createDir(root / "tests" / "fixtures")

  let kinds = [skMarcher, skDriftling, skMarcher, skDriftling]
  var match = newSim(fixtureConfig(960), meadow)
  match.runEpisode(provider(kinds))

  var digests = newJArray()
  for frame in match.keyframes:
    digests.add(%*{"t": frame["t"].getInt(), "d": frame["d"].getBiggestInt()})
  writeFile(root / "tests" / "fixtures" / "golden_digests.json",
    pretty(%*{
      "game_version": GameVersion,
      "seed": 42,
      "ticks": 960,
      "baselines": ["marcher", "driftling", "marcher", "driftling"],
      "keyframes": digests
    }, 2) & "\n")

  var turnsLlm, fallbackTurns: array[Colonies, int]
  var causes: array[Colonies, array[5, int]]
  let names = @["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
  let kindNames = @["scripted", "scripted", "scripted", "scripted"]
  let results = resultsJson(match, names, kindNames, turnsLlm, fallbackTurns,
    causes)
  writeFile(root / "tests" / "fixtures" / "sample_replay.json",
    $buildReplay(match, names, kindNames, results))

  echo "recorded ", match.keyframes.len, " keyframe digests and a ",
    match.tick, "-tick replay"
