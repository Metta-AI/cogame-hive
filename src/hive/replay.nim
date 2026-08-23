## The replay: strict UTF-8 JSON, `hive.replay.v1`.
##
## *Deviation from paintbot, deliberate:* paintbot writes the binary
## `COWLDCTF` format. Hive writes UTF-8 JSON because SPEC check 4 fetches the
## replay from S3 and requires valid UTF-8 JSON with a matching `protocol` and
## a legal `results.reason`, and the shared `tools/ci/docker_smoke.sh` defaults
## to `SMOKE_REQUIRE_REPLAY_JSON=1`.
##
## The input log is the DOCTRINE STREAM - 20 turns x 4 seats of nine integers
## and a block - because the ant kernel is a pure function of
## `(seed, field, doctrines)`. That is why hive's replay is small and why the
## viewer can re-derive the pheromone field, which no keyframe could carry.
##
## Forked from paintbot's `replay_runtime.nim` + `replays.nim`: the
## `parseReplayBytes` / `initReplayRuntime` / `advanceReplayFrame` shape the
## wasm viewer drives, including the hash-mismatch surface.

import std/[base64, json, strutils, unicode]
import types, config, field, state, doctrine, sim, rules

const
  ReplayProtocol* = "hive.replay.v1"
  ReplayFormatVersion* = 1

type
  ReplayData* = object
    protocol*: string
    formatVersion*: int
    gameVersion*: string
    seed*: int
    config*: GameConfig
    fieldSpec*: JsonNode
    seatNests*: array[Colonies, int]
    names*: JsonNode
    ticksPerSecond*: int
    turnTicks*: int
    tickCount*: int
    doctrines*: seq[array[Colonies, ResolvedDoctrine]]
    keyframes*: JsonNode
    antBytes*: seq[uint8]
    events*: JsonNode
    results*: JsonNode

  ReplayPlayer* = ref object
    data*: ReplayData
    match*: Sim
    hashMismatchTick*: int
    mismatchQuit*: bool

proc buildReplay*(
  match: Sim,
  names: seq[string],
  policyKinds: seq[string],
  results: JsonNode
): JsonNode =
  ## Everything the viewer needs, and nothing it does not: names, colours,
  ## policy kinds, config, field geometry, the seat -> nest permutation, the
  ## doctrine stream, per-second states, events, the seed and the results.
  var players = newJArray()
  var aliases = newJArray()
  var colours = newJArray()
  var kinds = newJArray()
  var seatNests = newJArray()
  for seat in 0 ..< Colonies:
    let colony = match.seatNest[seat]
    players.add(%(if seat < names.len: names[seat] else: "P" & $(seat + 1)))
    aliases.add(%match.meadow.nests[colony].alias)
    colours.add(%match.meadow.nests[colony].colour)
    kinds.add(%(if seat < policyKinds.len: policyKinds[seat] else: "scripted"))
    seatNests.add(%colony)
  var keyframes = newJArray()
  for frame in match.keyframes:
    keyframes.add(frame)
  var doctrines = newJArray()
  for entry in match.doctrineLog:
    doctrines.add(entry)
  %*{
    "protocol": ReplayProtocol,
    "format_version": ReplayFormatVersion,
    "game_version": GameVersion,
    "seed": match.config.seed,
    "config": configJson(match.config),
    "field": match.meadow.spec,
    "seat_nests": seatNests,
    "names": {
      "players": players,
      "aliases": aliases,
      "policy_kinds": kinds,
      "colours": colours
    },
    "ticks_per_second": TargetFps,
    "turn_ticks": match.config.turnTicks,
    "tick_count": match.tick,
    "doctrines": doctrines,
    "keyframes": keyframes,
    "ants_b64": encode(match.antBytes),
    "events": state.toJson(match.events),
    "results": results
  }

proc parseReplayBytes*(bytes: string): ReplayData =
  ## Strict: a bad protocol, a truncated document, a base64 length that does
  ## not match the keyframe count, or an out-of-range doctrine integer is
  ## rejected with a message rather than a crash.
  if validateUtf8(bytes) != -1:
    raise newException(HiveError, "replay bytes are not valid UTF-8")
  let node =
    try: parseJson(bytes)
    except CatchableError as error:
      raise newException(HiveError, "replay is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(HiveError, "replay must be a JSON object")
  result.protocol = node{"protocol"}.getStr()
  if result.protocol != ReplayProtocol:
    raise newException(HiveError,
      "unsupported replay protocol: " & result.protocol)
  result.formatVersion = node{"format_version"}.getInt(1)
  result.gameVersion = node{"game_version"}.getStr("1")
  result.seed = node{"seed"}.getInt()
  if not node.hasKey("config"):
    raise newException(HiveError, "replay has no config")
  result.config = configFromJson(node["config"])
  result.config.seed = result.seed
  if not node.hasKey("field"):
    raise newException(HiveError, "replay has no field")
  result.fieldSpec = node["field"]
  if not node.hasKey("seat_nests") or node["seat_nests"].len != Colonies:
    raise newException(HiveError, "replay has no seat_nests")
  for seat in 0 ..< Colonies:
    result.seatNests[seat] = node["seat_nests"][seat].getInt()
  result.names = node{"names"}
  result.ticksPerSecond = node{"ticks_per_second"}.getInt(TargetFps)
  result.turnTicks = node{"turn_ticks"}.getInt(result.config.turnTicks)
  result.tickCount = node{"tick_count"}.getInt()
  result.keyframes = node{"keyframes"}
  if result.keyframes.isNil or result.keyframes.kind != JArray:
    raise newException(HiveError, "replay has no keyframes")
  result.events = node{"events"}
  result.results = node{"results"}

  let turns = (result.tickCount + result.turnTicks - 1) div result.turnTicks
  result.doctrines = newSeq[array[Colonies, ResolvedDoctrine]](max(0, turns))
  for entry in 0 ..< result.doctrines.len:
    for seat in 0 ..< Colonies:
      result.doctrines[entry][seat] =
        ResolvedDoctrine(doctrine: defaultDoctrine(), source: dsScripted)
  if node.hasKey("doctrines"):
    for record in node["doctrines"]:
      let turn = record{"turn"}.getInt(-1)
      let seat = record{"seat"}.getInt(-1)
      if turn < 0 or turn >= result.doctrines.len or
          seat < 0 or seat >= Colonies:
        raise newException(HiveError,
          "doctrine record out of range: turn " & $turn & " seat " & $seat)
      for key in ["scouts", "trail_gain", "poach", "spread", "lay_food",
          "lay_home", "focus_weight"]:
        if record.hasKey(key) and record[key].kind == JInt:
          let value = record[key].getInt()
          if value < 0 or value > 100:
            raise newException(HiveError,
              "doctrine " & key & " out of range: " & $value)
      result.doctrines[turn][seat] = ResolvedDoctrine(
        doctrine: doctrine.fromJson(record),
        source:
          (case record{"source"}.getStr("scripted")
           of "llm": dsLlm
           of "fallback": dsFallback
           else: dsScripted),
        latencyMs: record{"latency_ms"}.getInt(0)
      )

  let raw = node{"ants_b64"}.getStr()
  let decoded =
    try: decode(raw)
    except CatchableError:
      raise newException(HiveError, "ants_b64 is not valid base64")
  result.antBytes = newSeq[uint8](decoded.len)
  for index in 0 ..< decoded.len:
    result.antBytes[index] = uint8(decoded[index])
  ## Keyframes land every 24 ticks, so their count is a function of
  ## `tick_count`. A document whose header and body disagree is rejected here
  ## rather than half-played.
  if result.tickCount < 0:
    raise newException(HiveError, "tick_count must not be negative")
  let wantedFrames = (result.tickCount + 23) div 24
  if result.keyframes.len != wantedFrames:
    raise newException(HiveError,
      "tick_count " & $result.tickCount & " implies " & $wantedFrames &
      " keyframes, got " & $result.keyframes.len)
  if result.keyframes.len > 0 and
      result.keyframes[^1]{"t"}.getInt(-1) >= result.tickCount:
    raise newException(HiveError, "the last keyframe is past tick_count")
  let expected = result.keyframes.len * Colonies *
    result.config.antsPerColony * 3
  if result.antBytes.len != expected:
    raise newException(HiveError,
      "ants_b64 decodes to " & $result.antBytes.len & " bytes, expected " &
      $expected)

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit = false
): ReplayPlayer =
  ## Rebuilds the match from `seed` + `field` + `seat_nests` + `doctrines`.
  let meadow = parseFieldSpec(data.fieldSpec)
  var gameConfig = data.config
  gameConfig.seed = data.seed
  result = ReplayPlayer(
    data: data,
    match: newSim(gameConfig, meadow),
    hashMismatchTick: -1,
    mismatchQuit: mismatchQuit
  )
  result.match.recording = false
  for seat in 0 ..< Colonies:
    if result.match.seatNest[seat] != data.seatNests[seat]:
      raise newException(HiveError,
        "seat_nests disagree with the seed-derived permutation")

proc keyframeDigest(data: ReplayData, tick: int): int64 =
  ## The recorded digest at a tick, or -1 when there is no keyframe there.
  ## BiggestInt throughout: a u32 digest does not fit a wasm32 `int`, and
  ## `getInt` would raise "value out of range" in the browser build.
  let index = tick div 24
  if index < 0 or index >= data.keyframes.len:
    return -1
  if data.keyframes[index]{"t"}.getInt(-1) != tick:
    return -1
  data.keyframes[index]{"d"}.getBiggestInt(0)

proc checkDigest*(player: ReplayPlayer) =
  ## Compares the digest of the keyframe the sim JUST produced against the
  ## recorded one. The first mismatch lights `#mmwarn` and playback continues
  ## (paintbot's `mismatchQuit = false` default, kept).
  if player.hashMismatchTick >= 0 or player.match.lastDigestTick < 0:
    return
  let recorded = keyframeDigest(player.data, player.match.lastDigestTick)
  if recorded < 0:
    return
  if int64(player.match.lastDigest) != recorded:
    player.hashMismatchTick = player.match.lastDigestTick
    if player.mismatchQuit:
      raise newException(HiveError,
        "replay hash mismatch at tick " & $player.match.lastDigestTick)

proc stepOne(player: ReplayPlayer) =
  let match = player.match
  if match.tick >= player.data.tickCount:
    return
  if match.tick mod match.config.turnTicks == 0:
    let turn = match.tick div match.config.turnTicks
    if turn < player.data.doctrines.len:
      match.installDoctrines(player.data.doctrines[turn])
  let before = match.lastDigestTick
  match.stepTick()
  if match.lastDigestTick != before:
    player.checkDigest()

proc rewindTo(player: ReplayPlayer, tick: int) =
  ## A backward seek restarts from the nearest in-memory turn snapshot and
  ## replays at most one turn - under 15 ms - instead of paintbot's
  ## replay-from-zero.
  let turnTicks = player.match.config.turnTicks
  let wanted = max(0, tick div turnTicks)
  var index = min(wanted, player.match.snapshots.len - 1)
  if index < 0:
    return
  player.match.restoreSnapshot(player.match.snapshots[index])

proc seekTo*(player: ReplayPlayer, tick: int) =
  let target = max(0, min(tick, player.data.tickCount))
  if target < player.match.tick:
    player.rewindTo(target)
  while player.match.tick < target:
    player.stepOne()

proc advanceReplayFrame*(player: ReplayPlayer, seekTicks: seq[int]) =
  ## One frame: honour a pending seek, else advance a single tick.
  if seekTicks.len > 0:
    player.seekTo(seekTicks[^1])
    return
  player.stepOne()

proc finished*(player: ReplayPlayer): bool =
  player.match.tick >= player.data.tickCount
