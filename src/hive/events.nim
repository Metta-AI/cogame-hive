## The event vocabulary. Forked from paintbot's `src/ctf/events.nim`: the
## kind -> JSON-key discipline is kept verbatim in shape, including the
## trailing summary row of `eventsJsonl`.
##
## Every record carries `t` (tick) and `turn` where meaningful. The
## high-frequency `deliver` and `harvest` records use short keys on purpose -
## they are the bulk of the replay's event stream.

import std/json
import types

type
  SimEventKind* = enum
    evMatchStart = "match_start"
    evTurnStart = "turn_start"
    evDoctrine = "doctrine"
    evFallback = "fallback"
    evBudgetGuard = "budget_guard"
    evRecall = "recall"
    evSourceSpawn = "source_spawn"
    evSourceGone = "source_gone"
    evHarvest = "harvest"
    evDeliver = "deliver"
    evRaid = "raid"
    evTrailWar = "trail_war"
    evEnd = "end"

proc newEvent*(kind: SimEventKind, tick: int): JsonNode =
  %*{"type": $kind, "t": tick}

proc matchStart*(
  tick, seed: int,
  fieldName: string,
  colonies: JsonNode,
  antsPerColony, episodeTicks: int
): JsonNode =
  result = newEvent(evMatchStart, tick)
  result["seed"] = %seed
  result["field"] = %fieldName
  result["colonies"] = colonies
  result["ants_per_colony"] = %antsPerColony
  result["episode_ticks"] = %episodeTicks

proc turnStart*(tick, turn: int, delivered: array[Colonies, int],
    sourcesLive: int): JsonNode =
  result = newEvent(evTurnStart, tick)
  result["turn"] = %turn
  result["delivered"] = %delivered
  result["sources_live"] = %sourcesLive

proc doctrineEvent*(
  tick, turn, seat: int,
  colony: string,
  source: DoctrineSource,
  latencyMs: int,
  body: JsonNode
): JsonNode =
  result = newEvent(evDoctrine, tick)
  result["turn"] = %turn
  result["seat"] = %seat
  result["colony"] = %colony
  result["source"] = %($source)
  result["latency_ms"] = %latencyMs
  for key, value in body:
    result[key] = value

proc fallbackEvent*(tick, turn, seat, attempt: int, cause, detail: string):
    JsonNode =
  result = newEvent(evFallback, tick)
  result["turn"] = %turn
  result["seat"] = %seat
  result["attempt"] = %attempt
  result["cause"] = %cause
  result["detail"] = %detail

proc budgetGuard*(tick, turn: int, remaining: float): JsonNode =
  result = newEvent(evBudgetGuard, tick)
  result["turn"] = %turn
  result["remaining_s"] = %remaining

proc recallEvent*(tick, turn: int, colony: string, recalled: int): JsonNode =
  result = newEvent(evRecall, tick)
  result["turn"] = %turn
  result["colony"] = %colony
  result["ants_recalled"] = %recalled

proc sourceSpawn*(tick: int, kind: string, orbit: int, sources: JsonNode):
    JsonNode =
  result = newEvent(evSourceSpawn, tick)
  result["kind"] = %kind
  result["orbit"] = %orbit
  result["sources"] = sources

proc sourceGone*(tick, source, cx, cy: int, cause: string, taken: JsonNode):
    JsonNode =
  result = newEvent(evSourceGone, tick)
  result["source"] = %source
  result["cell"] = %[cx, cy]
  result["cause"] = %cause
  result["taken"] = taken

proc harvestEvent*(tick, source, colony, units: int): JsonNode =
  result = newEvent(evHarvest, tick)
  result["s"] = %source
  result["c"] = %colony
  result["u"] = %units

proc deliverEvent*(tick, colony, running, source, raid: int): JsonNode =
  result = newEvent(evDeliver, tick)
  result["c"] = %colony
  result["n"] = %running
  result["s"] = %source
  result["r"] = %raid

proc raidEvent*(tick: int, colony, victim: string, source, units: int):
    JsonNode =
  result = newEvent(evRaid, tick)
  result["colony"] = %colony
  result["victim"] = %victim
  result["source"] = %source
  result["units"] = %units

proc trailWar*(tick, bx, by: int, colonies, strengths: JsonNode): JsonNode =
  result = newEvent(evTrailWar, tick)
  result["block"] = %[bx, by]
  result["colonies"] = colonies
  result["strengths"] = strengths

proc endEvent*(
  tick: int,
  reason: EndReason,
  rule: EndRule,
  delivered: JsonNode,
  scores: JsonNode,
  winner: JsonNode
): JsonNode =
  result = newEvent(evEnd, tick)
  result["reason"] = %($reason)
  result["end_rule"] = %($rule)
  result["delivered"] = delivered
  result["scores"] = scores
  result["winner"] = winner

proc eventsJsonl*(events: seq[JsonNode], summary: JsonNode): string =
  ## One JSON object per line plus a trailing summary row - paintbot's shape,
  ## kept so `COGAME_EVENTS_URI` consumers do not have to special-case hive.
  for event in events:
    result.add($event)
    result.add("\n")
  result.add($summary)
  result.add("\n")
