## Hive entrypoint: reads the Coworld runtime contract and starts either a
## live episode server or a replay viewer server.
##
## Forked from `src/ctf.nim`, including the rule that seed randomisation
## happens BEFORE `config.update` so every seed-derived draw - here the
## seat -> nest permutation, the orbit spawn cells, the kernel's tie-noise and
## the release-bearing draw - follows the final seed.

import std/[json, os, sysrand]
import bitworld/runtime
import hive/[types, config, state, server]

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed.
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false  ## config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(HiveError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quitError(error.msg)

  if runtimeConfig.replayMode:
    try:
      runReplayServer(runtimeConfig)
    except CatchableError as error:
      quitError("replay mode failed: " & error.msg)
  else:
    if getEnv("COGAME_CONFIG_URI").len == 0 and runtimeConfig.config.len == 0:
      quitError("COGAME_CONFIG_URI is not set (see --help)")
    var gameConfig = defaultGameConfig()
    try:
      if seedPinned(runtimeConfig.config):
        gameConfig.update(runtimeConfig.config)
      else:
        gameConfig.seed = randomSeed()
        gameConfig.update(stripUnpinnedSeed(runtimeConfig.config))
        echo "hive: seed not pinned; randomized"
    except CatchableError as error:
      quitError("invalid config: " & error.msg)
    echo "hive: host=", runtimeConfig.host, " port=", runtimeConfig.port,
      " seed=", gameConfig.seed, " seats=", gameConfig.numAgents,
      " ants=", gameConfig.antsPerColony,
      " ticks=", gameConfig.episodeTicks,
      " turns=", turnsOf(gameConfig),
      " field=", gameConfig.fieldPath
    try:
      runGameServer(gameConfig, runtimeConfig)
    except CatchableError as error:
      quitError(error.msg)
