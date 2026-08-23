## Turn clock, delivery accounting, the invariant guards, the score, the
## results document and the headless episode driver.
##
## The driver is deliberately not in `server.nim`: the tests, the wasm viewer
## and the game server must all advance the identical loop, and a doctrine
## provider callback is the only thing that differs between them.

import std/[json, math]
import types, field, pheromones, sources, state, events, labels, doctrine, sim

export sim

type
  DoctrineProvider* = proc (
    match: Sim,
    turn: int
  ): array[Colonies, ResolvedDoctrine] {.closure.}

  BudgetProbe* = proc (match: Sim, turn: int): bool {.closure.}
    ## Returns true when the wall clock says stop NOW (step 15's deadline).

proc invariantsOk*(match: Sim): bool =
  ## Step 15's guard set. A trip ends the episode `fault` / `sim_fault`.
  for ant in match.antState:
    if not match.meadow.onField(int(ant.cx), int(ant.cy)):
      match.faultDetail = "ant off field"
      return false
    if match.meadow.isRock(int(ant.cx), int(ant.cy)):
      match.faultDetail = "ant on rock"
      return false
  for item in match.sources.items:
    if item.amount < 0'i32:
      match.faultDetail = "source amount below zero"
      return false
  for colony in 0 ..< Colonies:
    if match.delivered[colony] < match.deliveredTurnStart[colony]:
      match.faultDetail = "delivered counter decreased"
      return false
    for plane in 0 .. 1:
      for value in match.planes.cells[colony][plane]:
        if int(value) > match.config.pheromoneMax:
          match.faultDetail = "pheromone above cap"
          return false
  true

proc scores*(match: Sim): array[Colonies, float] =
  ## Share of all food returned, in SLOT order. Higher is better and
  ## `sum(score) == 1.0` exactly for every legal outcome: the fourth value is
  ## the residual, so the four printed numbers sum to exactly 1.0.
  var total = 0
  for colony in 0 ..< Colonies:
    total += match.delivered[colony]
  if total == 0:
    for seat in 0 ..< Colonies:
      result[seat] = 0.25
    return
  var running = 0.0
  for seat in 0 ..< Colonies - 1:
    result[seat] = match.delivered[match.seatNest[seat]].float / total.float
    running += result[seat]
  result[Colonies - 1] = 1.0 - running

proc faultScores*(): array[Colonies, float] =
  for seat in 0 ..< Colonies:
    result[seat] = 0.25

proc winnerSlot*(match: Sim): int =
  ## The slot index of the unique maximum, or -1 when the maximum is tied.
  var best = -1
  var bestSeat = -1
  var ties = 0
  for seat in 0 ..< Colonies:
    let value = match.delivered[match.seatNest[seat]]
    if value > best:
      best = value
      bestSeat = seat
      ties = 1
    elif value == best:
      inc ties
  if ties == 1: bestSeat else: -1

proc totalDelivered*(match: Sim): int =
  for colony in 0 ..< Colonies:
    result += match.delivered[colony]

proc secondsLeft*(match: Sim): float =
  round((match.config.episodeTicks - match.tick).float /
    TargetFps.float * 10.0) / 10.0

proc endMatch*(match: Sim, reason: EndReason, rule: EndRule) =
  if match.finished:
    return
  match.finished = true
  match.reason = reason
  match.rule = rule
  let scored = if reason == erFault: faultScores() else: match.scores()
  var scoreJson = newJArray()
  for value in scored:
    scoreJson.add(%value)
  var deliveredJson = newJArray()
  for seat in 0 ..< Colonies:
    deliveredJson.add(%match.delivered[match.seatNest[seat]])
  let slot = if reason == erFault: -1 else: match.winnerSlot()
  match.events.add(endEvent(match.tick, reason, rule, deliveredJson,
    scoreJson, (if slot >= 0: %slot else: newJNull())))

proc runEpisode*(
  match: Sim,
  provide: DoctrineProvider,
  outOfTime: BudgetProbe = nil
) =
  ## The whole loop, resolution order intact. `provide` is called once at the
  ## first tick of every turn and must never block unboundedly - bounding it
  ## is the caller's job and the reason the probe exists.
  while not match.finished:
    if match.tick mod match.config.turnTicks == 0:
      ## The clock rolls FIRST, so the views `provide` builds carry this
      ## turn's number and last turn's delivery count.
      match.beginTurn()
      match.installDoctrines(provide(match, match.turn))
    match.stepTick()
    if match.tick >= match.config.episodeTicks:
      match.endMatch(erComplete, euFullTime)
      break
    if outOfTime != nil and outOfTime(match, match.tick div match.config.turnTicks):
      match.endMatch(erDeadline, euWallClock)
      break
    if match.tick mod KeyframePeriod == 0 and not match.invariantsOk():
      match.endMatch(erFault, euSimFault)
      break

# ---- results ----------------------------------------------------------------

proc fallbackCauseJson*(counts: array[Colonies, array[5, int]], seat: int):
    JsonNode =
  %*{
    "timeout": counts[seat][0],
    "parse_error": counts[seat][1],
    "transport_error": counts[seat][2],
    "no_credentials": counts[seat][3],
    "budget_guard": counts[seat][4]
  }

const FallbackCauses* = ["timeout", "parse_error", "transport_error",
  "no_credentials", "budget_guard"]

proc causeIndex*(cause: string): int =
  for index, name in FallbackCauses:
    if name == cause:
      return index
  1

proc resultsJson*(
  match: Sim,
  names: seq[string],
  policyKinds: seq[string],
  turnsLlm: array[Colonies, int],
  fallbackTurns: array[Colonies, int],
  fallbackCauses: array[Colonies, array[5, int]]
): JsonNode =
  ## The closed results document. Adding or removing a key here means editing
  ## `coworld_manifest_template.json`'s `results_schema` in the same commit.
  let scored = if match.reason == erFault: faultScores() else: match.scores()
  let slot = if match.reason == erFault: -1 else: match.winnerSlot()
  var
    namesJson = newJArray()
    aliases = newJArray()
    colours = newJArray()
    nests = newJArray()
    kinds = newJArray()
    scoresJson = newJArray()
    win = newJArray()
    delivered = newJArray()
    harvested = newJArray()
    raidedUnits = newJArray()
    raidedFromYou = newJArray()
    peak = newJArray()
    antCounts = newJArray()
    recalls = newJArray()
    llmTurns = newJArray()
    fallbacks = newJArray()
    causes = newJArray()
  for seat in 0 ..< Colonies:
    let colony = match.seatNest[seat]
    namesJson.add(%(if seat < names.len: names[seat] else: "P" & $(seat + 1)))
    aliases.add(%match.meadow.nests[colony].alias)
    colours.add(%match.meadow.nests[colony].colour)
    nests.add(%[match.meadow.nests[colony].cx, match.meadow.nests[colony].cy])
    kinds.add(%(if seat < policyKinds.len: policyKinds[seat] else: "scripted"))
    scoresJson.add(%scored[seat])
    win.add(%(slot == seat))
    delivered.add(%match.delivered[colony])
    harvested.add(%match.harvested[colony])
    raidedUnits.add(%match.raidedUnits[colony])
    raidedFromYou.add(%match.raidedFromYou[colony])
    peak.add(%match.peakFoodTrail[colony])
    antCounts.add(%match.config.antsPerColony)
    recalls.add(%match.recalls[colony])
    llmTurns.add(%turnsLlm[seat])
    fallbacks.add(%fallbackTurns[seat])
    causes.add(fallbackCauseJson(fallbackCauses, seat))
  %*{
    "names": namesJson,
    "aliases": aliases,
    "colours": colours,
    "nests": nests,
    "policy_kinds": kinds,
    "scores": scoresJson,
    "win": win,
    "delivered": delivered,
    "harvested": harvested,
    "raided_units": raidedUnits,
    "raided_from_you": raidedFromYou,
    "peak_food_trail": peak,
    "ants": antCounts,
    "recalls": recalls,
    "turns_llm": llmTurns,
    "fallback_turns": fallbacks,
    "fallback_causes": causes,
    "total_delivered": match.totalDelivered(),
    "sources_spawned": match.sources.spawned,
    "reason": $match.reason,
    "end_rule": $match.rule,
    "winner": (if slot >= 0: %slot else: newJNull()),
    "final_tick": match.tick,
    "final_turn": (match.tick + match.config.turnTicks - 1) div
      match.config.turnTicks,
    "seed": match.config.seed
  }

const ResultsKeys* = [
  "names", "aliases", "colours", "nests", "policy_kinds", "scores", "win",
  "delivered", "harvested", "raided_units", "raided_from_you",
  "peak_food_trail", "ants", "recalls", "turns_llm", "fallback_turns",
  "fallback_causes", "total_delivered", "sources_spawned", "reason",
  "end_rule", "winner", "final_tick", "final_turn", "seed"
]
