## An end-to-end episode that writes a replay, parsed STRICTLY, then
## re-derived: every keyframe digest and every byte of ants_b64 must come back
## identical from `seed` + `field` + `seat_nests` + `doctrines` alone.

import std/[base64, json, os, strutils, unicode]
import support/helpers
import hive/replay

const Names = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]

proc episode(): tuple[match: Sim, results: JsonNode, bytes: string] =
  var config = testConfig(960, 42)
  config.players = @[
    PlayerConfig(name: Names[0]), PlayerConfig(name: Names[1]),
    PlayerConfig(name: Names[2]), PlayerConfig(name: Names[3])
  ]
  var match = newSim(config, testField())
  var memory: array[Colonies, BaselineMemory]
  let kinds = [skMarcher, skDriftling, skMarcher, skDriftling]
  let provide = proc (m: Sim, turn: int):
      array[Colonies, ResolvedDoctrine] {.closure.} =
    for seat in 0 ..< Colonies:
      result[seat] = scriptedResolved(buildView(m, seat), kinds[seat], turn,
        memory[seat])
      ## Force a non-ASCII `say` into the doctrine stream so the UTF-8 path is
      ## real, not hypothetical.
      if turn == 1 and seat == 0:
        result[seat].doctrine.say = "road \u00e9\u00e8 \u{1F41C}"
  match.runEpisode(provide)
  var turnsLlm, fallbackTurns: array[Colonies, int]
  var causes: array[Colonies, array[5, int]]
  let results = resultsJson(match, @Names,
    @["scripted", "scripted", "scripted", "scripted"], turnsLlm,
    fallbackTurns, causes)
  (match: match, results: results,
   bytes: $buildReplay(match, @Names,
     @["scripted", "scripted", "scripted", "scripted"], results))

proc main() =
  let run = episode()
  let tmp = getTempDir() / "hive-test-replay"
  createDir(tmp)
  let replayPath = tmp / "replay.json"
  let resultsPath = tmp / "results.json"
  writeFile(replayPath, run.bytes)
  writeFile(resultsPath, $run.results)

  block artifactsExist:
    check(fileExists(resultsPath) and getFileSize(resultsPath) > 0,
      "results.json is written and non-empty")
    check(fileExists(replayPath) and getFileSize(replayPath) > 0,
      "the replay is written and non-empty")
    report("a full scripted episode writes results.json and a replay")

  block strictUtf8:
    let raw = readFile(replayPath)
    checkEqual(validateUtf8(raw), -1, "the replay bytes are valid UTF-8")
    let node = parseJson(raw)
    checkEqual(node["protocol"].getStr(), "hive.replay.v1", "protocol")
    checkEqual(node["format_version"].getInt(), 1, "format_version")
    checkEqual(node["game_version"].getStr(), GameVersion, "game_version")
    var sawNonAscii = false
    for record in node["doctrines"]:
      if validateUtf8(record["say"].getStr()) != -1:
        check(false, "a recorded say is not valid UTF-8")
      for ch in record["say"].getStr():
        if ord(ch) > 127: sawNonAscii = true
    check(sawNonAscii,
      "the fixture really did force a non-ASCII say into the stream")
    report("the replay parses strictly and carries real non-ASCII text")

  block everyKey:
    let node = parseJson(readFile(replayPath))
    for key in ["protocol", "format_version", "game_version", "seed", "config",
        "field", "seat_nests", "names", "ticks_per_second", "turn_ticks",
        "tick_count", "doctrines", "keyframes", "ants_b64", "events",
        "results"]:
      check(node.hasKey(key), "the replay carries " & key)
    for key in ["field", "names", "config", "seat_nests", "doctrines",
        "keyframes", "events", "results"]:
      check(node[key].len > 0, key & " is non-empty")
    checkEqual(node["names"]["players"].len, Colonies, "four player names")
    checkEqual(node["names"]["aliases"].len, Colonies, "four aliases")
    checkEqual(node["names"]["colours"].len, Colonies, "four colours")
    checkEqual(node["names"]["policy_kinds"].len, Colonies, "four kinds")
    checkEqual(node["seat_nests"].len, Colonies, "four seat_nests")
    check(node["field"].hasKey("rock"), "the field spec is inlined verbatim")
    check(node["config"].hasKey("num_agents"), "the config is inlined")
    check(not node["config"].hasKey("tokens"),
      "tokens are NEVER written into the replay")
    checkEqual(node["results"]["reason"].getStr(), "complete", "legal reason")
    check(node["results"]["reason"].getStr() in
      ["complete", "deadline", "fault"], "reason is in the closed enum")
    report("every documented top-level key is present and non-empty")

  block antsB64:
    let node = parseJson(readFile(replayPath))
    let decoded = decode(node["ants_b64"].getStr())
    let expected = node["keyframes"].len * Colonies * 24 * 3
    checkEqual(decoded.len, expected,
      "ants_b64 decodes to keyframeCount x 96 x 3 bytes")
    report("ants_b64 has exactly the documented length")

  block eventStream:
    let node = parseJson(readFile(replayPath))
    var counts: array[Colonies, seq[int]]
    var spawns = 0
    var harvests = 0
    var delivers = 0
    for event in node["events"]:
      case event["type"].getStr()
      of "doctrine": counts[event["seat"].getInt()].add(event["turn"].getInt())
      of "source_spawn": inc spawns
      of "harvest": inc harvests
      of "deliver": inc delivers
      else: discard
    let turns = node["tick_count"].getInt() div node["turn_ticks"].getInt()
    for seat in 0 ..< Colonies:
      checkEqual(counts[seat].len, turns,
        "exactly one doctrine per seat per turn (seat " & $seat & ")")
      for turn in 0 ..< turns:
        checkEqual(counts[seat][turn], turn, "in turn order")
    check(spawns >= 1, "at least one source_spawn")
    check(harvests >= 1, "at least one harvest")
    check(delivers >= 1, "at least one deliver")
    report("the event stream is complete: " & $spawns & " spawns, " &
      $harvests & " harvests, " & $delivers & " deliveries")

  block rederive:
    ## The whole point: seed + field + seat_nests + doctrines reproduce the
    ## episode exactly.
    let data = parseReplayBytes(readFile(replayPath))
    let player = initReplayRuntime(data)
    var rebuilt: seq[uint8]
    var seenTick = -1
    while not player.finished():
      advanceReplayFrame(player, @[])
      if player.match.lastDigestTick != seenTick:
        seenTick = player.match.lastDigestTick
        for value in player.match.lastKeyframeAnts:
          rebuilt.add(value)
    checkEqual(player.hashMismatchTick, -1,
      "every keyframe digest re-derived identically")
    checkEqual(rebuilt.len, data.antBytes.len, "the same number of ant bytes")
    checkEqual(rebuilt, data.antBytes, "every byte of ants_b64 re-derived")
    checkEqual(player.match.tick, data.tickCount, "the re-run reached the end")
    report("re-deriving from the doctrine stream reproduces every digest " &
      "and every ant byte")

  block seeks:
    let data = parseReplayBytes(readFile(replayPath))
    let player = initReplayRuntime(data)
    player.seekTo(data.tickCount)
    checkEqual(player.match.tick, data.tickCount, "seek to end lands")
    player.seekTo(480)
    checkEqual(player.match.tick, 480, "seek to mid lands")
    player.seekTo(120)
    checkEqual(player.match.tick, 120, "seek backwards lands")
    checkEqual(player.hashMismatchTick, -1, "seeking never trips the digest")
    report("seek to end, to mid and backwards all land exactly")

  block rejectsGarbage:
    var raised = 0
    let good = readFile(replayPath)
    for broken in [
        good.replace("hive.replay.v1", "hive.replay.v9"),
        good[0 ..< good.len div 2],
        "not json at all",
        good.replace("\"ants_b64\":\"", "\"ants_b64\":\"AAAA"),
        good.replace("\"tick_count\":960", "\"tick_count\":1200"),
        good.replace("\"scouts\":55", "\"scouts\":5500")]:
      try:
        discard parseReplayBytes(broken)
      except HiveError, JsonParsingError:
        inc raised
    checkEqual(raised, 6, "every malformed replay is rejected with a message")
    report("malformed replays are rejected, not crashed on")

  removeDir(tmp)

main()
echo "test_replay: all checks passed"
