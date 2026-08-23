## GameConfig lifecycle - forked from paintbot's `src/ctf/sim_config.nim`.
## Defaults, the runtime JSON overlay, and the `configJson()` snapshot that is
## pinned verbatim into every replay.

import std/[json, strutils]
import types

const DefaultBonanzaTicks* = @[1200, 3600]

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: 4,
    antsPerColony: 24,
    episodeTicks: 4800,
    turnTicks: 240,
    antStepTicks: 2,
    cellPx: CellPx,
    pheromoneMax: 4000,
    pheromoneFloor: 4,
    pheromoneDecayNum: 248,
    decayPeriodTicks: 8,
    nestSenseCells: 12,
    maxOrbits: 3,
    sourceSpawnPeriod: 240,
    sourceAmount: 60,
    sourceLifeTicks: 1440,
    minNestClearance: 14,
    bonanzaTicks: DefaultBonanzaTicks,
    bonanzaAmount: 100,
    bonanzaLifeTicks: 900,
    raidRadius: 20,
    trailWarThreshold: 800,
    turnBudgetSeconds: 22.0,
    wallClockBudgetSeconds: 660.0,
    playerConnectTimeoutSeconds: 90.0,
    episodeTimeoutSeconds: 1200,
    fieldPath: "meadow",
    showPlayerLabels: true,
    gameOverTicks: 96
  )

proc getIntOr(node: JsonNode, fallback: int): int =
  if node.isNil: return fallback
  case node.kind
  of JInt: node.getInt()
  of JFloat: int(node.getFloat())
  of JString:
    try: parseInt(node.getStr().strip()) except ValueError: fallback
  else: fallback

proc getFloatOr(node: JsonNode, fallback: float): float =
  if node.isNil: return fallback
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  of JString:
    try: parseFloat(node.getStr().strip()) except ValueError: fallback
  else: fallback

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node =
    try: parseJson(configJson)
    except CatchableError as error:
      raise newException(HiveError, "config is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(HiveError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  config.seed = node{"seed"}.getIntOr(config.seed)
  config.numAgents = node{"num_agents"}.getIntOr(config.numAgents)
  config.antsPerColony = node{"antsPerColony"}.getIntOr(config.antsPerColony)
  config.episodeTicks = node{"episodeTicks"}.getIntOr(config.episodeTicks)
  config.turnTicks = node{"turnTicks"}.getIntOr(config.turnTicks)
  config.antStepTicks = node{"antStepTicks"}.getIntOr(config.antStepTicks)
  config.cellPx = node{"cellPx"}.getIntOr(config.cellPx)
  config.pheromoneMax = node{"pheromoneMax"}.getIntOr(config.pheromoneMax)
  config.pheromoneFloor = node{"pheromoneFloor"}.getIntOr(config.pheromoneFloor)
  config.pheromoneDecayNum =
    node{"pheromoneDecayNum"}.getIntOr(config.pheromoneDecayNum)
  config.decayPeriodTicks =
    node{"decayPeriodTicks"}.getIntOr(config.decayPeriodTicks)
  config.nestSenseCells = node{"nestSenseCells"}.getIntOr(config.nestSenseCells)
  config.maxOrbits = node{"maxOrbits"}.getIntOr(config.maxOrbits)
  config.sourceSpawnPeriod =
    node{"sourceSpawnPeriod"}.getIntOr(config.sourceSpawnPeriod)
  config.sourceAmount = node{"sourceAmount"}.getIntOr(config.sourceAmount)
  config.sourceLifeTicks = node{"sourceLifeTicks"}.getIntOr(config.sourceLifeTicks)
  config.minNestClearance =
    node{"minNestClearance"}.getIntOr(config.minNestClearance)
  if node.hasKey("bonanzaTicks") and node["bonanzaTicks"].kind == JArray:
    config.bonanzaTicks = @[]
    for value in node["bonanzaTicks"]:
      config.bonanzaTicks.add(value.getIntOr(0))
  config.bonanzaAmount = node{"bonanzaAmount"}.getIntOr(config.bonanzaAmount)
  config.bonanzaLifeTicks =
    node{"bonanzaLifeTicks"}.getIntOr(config.bonanzaLifeTicks)
  config.raidRadius = node{"raidRadius"}.getIntOr(config.raidRadius)
  config.trailWarThreshold =
    node{"trailWarThreshold"}.getIntOr(config.trailWarThreshold)
  config.turnBudgetSeconds =
    node{"turnBudgetSeconds"}.getFloatOr(config.turnBudgetSeconds)
  config.wallClockBudgetSeconds =
    node{"wallClockBudgetSeconds"}.getFloatOr(config.wallClockBudgetSeconds)
  config.playerConnectTimeoutSeconds =
    node{"playerConnectTimeoutSeconds"}.getFloatOr(
      config.playerConnectTimeoutSeconds)
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node{"player_connect_timeout_seconds"}.getFloatOr(
        config.playerConnectTimeoutSeconds)
  config.episodeTimeoutSeconds =
    node{"episodeTimeoutSeconds"}.getIntOr(config.episodeTimeoutSeconds)
  if node.hasKey("fieldPath"):
    config.fieldPath = node["fieldPath"].getStr(config.fieldPath)
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels = node["showPlayerLabels"].getBool(true)
  config.gameOverTicks = node{"gameOverTicks"}.getIntOr(config.gameOverTicks)

  if config.numAgents != Colonies:
    raise newException(HiveError,
      "hive seats exactly " & $Colonies & " colonies; num_agents=" &
      $config.numAgents)
  if config.antsPerColony < 1 or config.antsPerColony > 255:
    raise newException(HiveError, "antsPerColony must be 1..255")
  if config.turnTicks < 1:
    raise newException(HiveError, "turnTicks must be positive")
  if config.episodeTicks < config.turnTicks:
    raise newException(HiveError, "episodeTicks must cover at least one turn")
  if config.antStepTicks < 1:
    raise newException(HiveError, "antStepTicks must be positive")
  if config.pheromoneMax < 1 or config.pheromoneMax > 65535:
    raise newException(HiveError, "pheromoneMax must be 1..65535")

proc turnsOf*(config: GameConfig): int =
  ## Decision turns in the episode.
  (config.episodeTicks + config.turnTicks - 1) div config.turnTicks

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config as it is pinned into the replay. Tokens are
  ## deliberately excluded - they are credentials, not rules.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  var bonanza = newJArray()
  for value in config.bonanzaTicks:
    bonanza.add(%value)
  %*{
    "num_agents": config.numAgents,
    "antsPerColony": config.antsPerColony,
    "episodeTicks": config.episodeTicks,
    "turnTicks": config.turnTicks,
    "antStepTicks": config.antStepTicks,
    "cellPx": config.cellPx,
    "pheromoneMax": config.pheromoneMax,
    "pheromoneFloor": config.pheromoneFloor,
    "pheromoneDecayNum": config.pheromoneDecayNum,
    "decayPeriodTicks": config.decayPeriodTicks,
    "nestSenseCells": config.nestSenseCells,
    "maxOrbits": config.maxOrbits,
    "sourceSpawnPeriod": config.sourceSpawnPeriod,
    "sourceAmount": config.sourceAmount,
    "sourceLifeTicks": config.sourceLifeTicks,
    "minNestClearance": config.minNestClearance,
    "bonanzaTicks": bonanza,
    "bonanzaAmount": config.bonanzaAmount,
    "bonanzaLifeTicks": config.bonanzaLifeTicks,
    "raidRadius": config.raidRadius,
    "trailWarThreshold": config.trailWarThreshold,
    "turnBudgetSeconds": config.turnBudgetSeconds,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "playerConnectTimeoutSeconds": config.playerConnectTimeoutSeconds,
    "fieldPath": config.fieldPath,
    "showPlayerLabels": config.showPlayerLabels,
    "gameOverTicks": config.gameOverTicks,
    "players": players
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuilds a config from a replay's `config` key.
  result = defaultGameConfig()
  result.update($node)

