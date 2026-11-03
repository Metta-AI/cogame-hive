## Complete ordinary games on each shipped topology, native replay parity,
## and manifest wiring. No model, private teacher label or learned outcome.
import std/[json, os]
import support/helpers
import hive/replay

proc main() =
  let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
  let ordinary = manifest["variants"][0]["game_config"]
  let alternate = manifest["variants"][2]["game_config"]
  var resolved = parseJson($alternate)
  resolved["fieldPath"] = %"meadow"
  checkEqual(resolved, ordinary, "crossroads changes only the authored field")
  checkEqual(defaultGameConfig().fieldPath, "meadow", "default stays meadow")
  let meadow = loadField("meadow")
  let crossroads = loadField("crossroads")
  var changed = 0
  for i in 0 ..< meadow.rock.len:
    if meadow.rock[i] != crossroads.rock[i]: inc changed
  check(changed >= 1000, "alternate changes substantial physical geometry")
  for name in ["meadow", "crossroads"]:
    let field = loadField(name)
    checkEqual(field.freeFloorComponents(), 1, "connected free floor: " & name)
    var rocks = 0
    for y in 0 ..< field.rows:
      for x in 0 ..< field.cols:
        if field.isRock(x, y): inc rocks
        checkEqual(field.isRock(x, y), field.isRock(field.cols-1-x, y), "x mirror")
        checkEqual(field.isRock(x, y), field.isRock(x, field.rows-1-y), "y mirror")
    check(rocks * 100 div field.rock.len >= 5 and
      rocks * 100 div field.rock.len <= 30, "5-30 percent rock: " & name)
    var config = defaultGameConfig()
    config.seed = 42
    config.fieldPath = name
    config.players = @[PlayerConfig(name: "P1"), PlayerConfig(name: "P2"),
      PlayerConfig(name: "P3"), PlayerConfig(name: "P4")]
    var match = newSim(config, field)
    match.runEpisode(scriptedProvider(allMarcher()))
    var llm, fallbacks: array[Colonies, int]
    var causes: array[Colonies, array[8, int]]
    let names = @["P1", "P2", "P3", "P4"]
    let kinds = @["scripted", "scripted", "scripted", "scripted"]
    let results = resultsJson(match, names, kinds, llm, fallbacks, causes)
    checkEqual(results["reason"].getStr(), "complete", "ordinary completion")
    checkEqual(match.tick, 4800, "full default horizon")
    checkEqual(match.keyframes.len, 200, "all default keyframes")
    check(results["total_delivered"].getInt() > 0, "ordinary foraging delivers food")
    let replay = buildReplay(match, names, kinds, results)
    checkEqual(replay["field"], field.spec, "original geometry is inlined verbatim")
    let data = parseReplayBytes($replay)
    let player = initReplayRuntime(data)
    var rebuilt: seq[uint8]
    var seenTick = -1
    while not player.finished():
      advanceReplayFrame(player, @[])
      if player.match.lastDigestTick != seenTick:
        seenTick = player.match.lastDigestTick
        for value in player.match.lastKeyframeAnts: rebuilt.add(value)
    checkEqual(player.hashMismatchTick, -1, "all replay digests agree: " & name)
    checkEqual(rebuilt, match.antBytes, "all ant bytes agree: " & name)
    let output = getEnv("HIVE_FIELD_REPLAY_DIR")
    if output.len > 0:
      createDir(output)
      writeFile(output / (name & ".json"), $replay)
    echo name, " full ordinary scripted game; rocks=", rocks,
      " changed_cells=", changed, " total_delivered=", results["total_delivered"]
  report("authored fields complete ordinary games and reproduce every native keyframe")
main()
