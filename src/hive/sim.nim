## The integer tick loop.
##
## Forked from paintbot's `src/ctf/sim.nim` with the CTF rule surface removed
## (guns, hitscan, aim, the vision cone and shadowcast FOV, grenades, the
## barrage, med kits, shields, the plasma arc, paint puddles, spray cans,
## lives / hit points / respawn, perks, handicaps, achievements, shouts,
## teams-as-sides) and the foraging rules put in its place. What survives is
## the loop, the field bake, the keyframe/digest discipline and the
## resolution-order contract.
##
## The resolution order below is exact and has no exceptions. "Ant order"
## always means ascending global index `g = nestIndex * antsPerColony +
## antIndex`.

import std/json
import types, field, pheromones, ants, sources, state, events, labels,
  doctrine

type
  Snapshot* = object
    ## A full in-memory state snapshot, taken at the top of every turn so a
    ## backward seek in the viewer replays at most one turn instead of the
    ## whole match. Snapshots are NEVER written to the replay.
    tick*: int
    turn*: int
    planes*: Planes
    sources*: SourceSet
    antState*: seq[Ant]
    rng*: Pcg
    delivered*: array[Colonies, int]
    harvested*: array[Colonies, int]

  Sim* = ref object
    config*: GameConfig
    meadow*: Field
    planes*: Planes
    sources*: SourceSet
    antState*: seq[Ant]
    rng*: Pcg
    tick*: int
    turn*: int
    turnRolled*: int   ## the last turn `beginTurn` rolled; -1 before the first

    seatNest*: array[Colonies, int]   ## seat -> nest (the colony it drives)
    nestSeat*: array[Colonies, int]   ## nest -> seat

    delivered*: array[Colonies, int]
    deliveredTurnStart*: array[Colonies, int]
    deliveredLastTurn*: array[Colonies, int]
    harvested*: array[Colonies, int]
    raidedUnits*: array[Colonies, int]
    raidedFromYou*: array[Colonies, int]
    peakFoodTrail*: array[Colonies, int]
    recalls*: array[Colonies, int]

    doctrines*: array[Colonies, Doctrine]
    doctrineKinds*: array[Colonies, DoctrineSource]
    hasDoctrine*: array[Colonies, bool]
    coefficients*: array[Colonies, Coefficients]

    sensed*: array[Colonies, seq[int]]
    contactCount*: array[Colonies, array[Colonies, seq[int]]]
    contactAnts*: array[Colonies, array[Colonies, seq[bool]]]
      ## Which of YOUR ants met that rival this turn, one flag per ant. The
      ## view reports the count of distinct ants involved, not the number of
      ## co-location samples.
    seenAmount*: array[Colonies, seq[int]]
    seenTurn*: array[Colonies, seq[int]]

    events*: EventBuffer
    recording*: bool           ## false while the viewer re-derives a match
    doctrineLog*: seq[JsonNode]
    keyframes*: seq[JsonNode]
    antBytes*: seq[uint8]
    keyframeCount*: int
    snapshots*: seq[Snapshot]
    lastDigest*: uint32
    lastDigestTick*: int
    lastKeyframeAnts*: seq[uint8]

    finished*: bool
    reason*: EndReason
    rule*: EndRule
    faultDetail*: string

const
  TrailWarPeriod* = 48
  HarvestPeriod* = 24
  KeyframePeriod* = 24

proc antsTotal*(sim: Sim): int {.inline.} =
  Colonies * sim.config.antsPerColony

proc nestOfSeat*(sim: Sim, seat: int): int {.inline.} = sim.seatNest[seat]
proc seatOfNest*(sim: Sim, nest: int): int {.inline.} = sim.nestSeat[nest]

proc aliasOf*(sim: Sim, nest: int): string {.inline.} =
  sim.meadow.nests[nest].alias

proc colonyKernel(sim: Sim, colony: int): Kernel =
  Kernel(
    cap: sim.config.pheromoneMax,
    nestSense: sim.config.nestSenseCells,
    nestCx: sim.meadow.nests[colony].cx,
    nestCy: sim.meadow.nests[colony].cy
  )

proc newSim*(gameConfig: GameConfig, meadow: Field,
    logEvents = false): Sim =
  ## Builds a match. The seat -> nest permutation is the FIRST draw off the
  ## stream, exactly once, so every later draw is a function of the seed and
  ## the doctrines alone.
  result = Sim(config: gameConfig, meadow: meadow, recording: true,
    lastDigestTick: -1, turnRolled: -1)
  result.rng = initPcg(gameConfig.seed)
  result.seatNest = seatPermutation(result.rng)
  result.nestSeat = invert(result.seatNest)
  result.planes = initPlanes(meadow.cols, meadow.rows)
  result.sources = initSourceSet(meadow.cols, meadow.rows)
  result.events = initEventBuffer(logEvents)
  result.antState = newSeq[Ant](Colonies * gameConfig.antsPerColony)
  for colony in 0 ..< Colonies:
    result.sensed[colony] = newSeq[int](BlockCount)
    for index in 0 ..< BlockCount:
      result.sensed[colony][index] = -1000
    for rival in 0 ..< Colonies:
      result.contactCount[colony][rival] = newSeq[int](BlockCount)
      result.contactAnts[colony][rival] = newSeq[bool](gameConfig.antsPerColony)
    result.seenAmount[colony] = @[]
    result.seenTurn[colony] = @[]
    result.doctrines[colony] = defaultDoctrine()
    result.coefficients[colony] =
      coefficients(result.doctrines[colony], gameConfig.antsPerColony)
    result.doctrineKinds[colony] = dsScripted
    for index in 0 ..< gameConfig.antsPerColony:
      let g = colony * gameConfig.antsPerColony + index
      result.antState[g] = Ant(
        cx: int32(meadow.nests[colony].cx),
        cy: int32(meadow.nests[colony].cy),
        heading: int32(index and 7),
        carrying: false,
        carriedFrom: -1'i32,
        held: false,
        scout: false
      )
  var colonies = newJArray()
  for seat in 0 ..< Colonies:
    let nest = result.seatNest[seat]
    colonies.add(%*{
      "alias": meadow.nests[nest].alias,
      "colour": meadow.nests[nest].colour,
      "nest": [meadow.nests[nest].cx, meadow.nests[nest].cy],
      "seat": seat
    })
  result.events.add(matchStart(0, gameConfig.seed, meadow.name, colonies,
    gameConfig.antsPerColony, gameConfig.episodeTicks))

# ---- digest -----------------------------------------------------------------

proc hiveStateDigest*(sim: Sim): uint32 =
  ## FNV-1a u32 over the raw bytes of every ant, every live source, the four
  ## delivered counters, the PCG state, the tick - AND all eight pheromone
  ## planes in full. Paintbot's `gameHash` idea widened to the whole state,
  ## which is what lets the wasm viewer prove it re-derived the same match.
  var hash = initFnv()
  hash.feedInt(sim.tick)
  for ant in sim.antState:
    hash.feedInt(int(ant.cx))
    hash.feedInt(int(ant.cy))
    hash.feedInt(int(ant.heading))
    hash.feedByte(if ant.carrying: 1'u8 else: 0'u8)
    hash.feedByte(if ant.held: 1'u8 else: 0'u8)
    hash.feedInt(int(ant.carriedFrom))
  for item in sim.sources.items:
    if not item.alive:
      continue
    hash.feedInt(int(item.id))
    hash.feedInt(int(item.cx))
    hash.feedInt(int(item.cy))
    hash.feedInt(int(item.amount))
  for colony in 0 ..< Colonies:
    hash.feedInt(sim.delivered[colony])
  hash.feedU64(sim.rng.state)
  hash.feedU64(sim.rng.inc)
  for colony in 0 ..< Colonies:
    for plane in 0 .. 1:
      for value in sim.planes.cells[colony][plane]:
        hash.feedU16(value)
  hash.value

# ---- snapshots --------------------------------------------------------------

proc takeSnapshot*(sim: Sim): Snapshot =
  Snapshot(
    tick: sim.tick,
    turn: sim.turn,
    planes: sim.planes,
    sources: sim.sources,
    antState: sim.antState,
    rng: sim.rng,
    delivered: sim.delivered,
    harvested: sim.harvested
  )

proc restoreSnapshot*(sim: Sim, snapshot: Snapshot) =
  sim.tick = snapshot.tick
  sim.turn = snapshot.turn
  ## A rewound turn is re-entered from the top, so its clock must roll again.
  sim.turnRolled = snapshot.turn - 1
  sim.planes = snapshot.planes
  sim.sources = snapshot.sources
  sim.antState = snapshot.antState
  sim.rng = snapshot.rng
  sim.delivered = snapshot.delivered
  sim.harvested = snapshot.harvested

# ---- turn install (resolution step 1) ---------------------------------------

proc beginTurn*(sim: Sim) =
  ## The first half of step 1, and it runs BEFORE the per-seat views are
  ## built: the turn clock advances and `delivered_last_turn` rolls. Doing it
  ## here rather than inside `installDoctrines` is what makes the view a seat
  ## sees for turn N read `"turn": N` and report the deliveries of turn N-1,
  ## which is the schema the design note pins. `sensed` and `contacts` are
  ## NOT cleared here - the view for turn N is exactly the record of turn
  ## N-1's walking, so they are cleared in `installDoctrines`, after it.
  ##
  ## Idempotent within a turn, so a caller that only calls `installDoctrines`
  ## still gets a correct clock.
  let turn = sim.tick div sim.config.turnTicks
  if sim.turnRolled == turn:
    return
  sim.turnRolled = turn
  sim.turn = turn
  for colony in 0 ..< Colonies:
    sim.deliveredLastTurn[colony] =
      sim.delivered[colony] - sim.deliveredTurnStart[colony]
    sim.deliveredTurnStart[colony] = sim.delivered[colony]

proc installDoctrines*(sim: Sim, resolved: array[Colonies, ResolvedDoctrine]) =
  ## Step 1. `resolved` is indexed by SEAT; colony state is indexed by NEST.
  sim.beginTurn()
  for colony in 0 ..< Colonies:
    for index in 0 ..< BlockCount:
      sim.sensed[colony][index] = -1000
    for rival in 0 ..< Colonies:
      for index in 0 ..< BlockCount:
        sim.contactCount[colony][rival][index] = 0
      for index in 0 ..< sim.contactAnts[colony][rival].len:
        sim.contactAnts[colony][rival][index] = false

  var delivered: array[Colonies, int]
  for seat in 0 ..< Colonies:
    delivered[seat] = sim.delivered[sim.seatNest[seat]]
  if sim.recording:
    sim.events.add(turnStart(sim.tick, sim.turn, delivered,
      sim.sources.liveCount()))

  for seat in 0 ..< Colonies:
    let colony = sim.seatNest[seat]
    let entry = resolved[seat]
    sim.doctrines[colony] = entry.doctrine
    sim.doctrineKinds[colony] = entry.source
    sim.hasDoctrine[colony] = true
    sim.coefficients[colony] =
      coefficients(entry.doctrine, sim.config.antsPerColony)
    let scoutCount = sim.coefficients[colony].scoutCount
    for index in 0 ..< sim.config.antsPerColony:
      let g = colony * sim.config.antsPerColony + index
      sim.antState[g].scout = index < scoutCount
      if not entry.doctrine.recall:
        sim.antState[g].held = false
    if entry.doctrine.recall:
      sim.recalls[colony].inc
      var recalled = 0
      for index in 0 ..< sim.config.antsPerColony:
        let g = colony * sim.config.antsPerColony + index
        if not sim.antState[g].held:
          inc recalled
      if sim.recording:
        sim.events.add(recallEvent(sim.tick, sim.turn,
          sim.meadow.nests[colony].alias, recalled))
    if sim.recording:
      let record = doctrineEvent(sim.tick, sim.turn, seat,
        sim.meadow.nests[colony].alias, entry.source, entry.latencyMs,
        entry.doctrine.toJson())
      sim.events.add(record)
      var logged = entry.doctrine.toJson()
      logged["turn"] = %sim.turn
      logged["seat"] = %seat
      logged["source"] = %($entry.source)
      logged["latency_ms"] = %entry.latencyMs
      sim.doctrineLog.add(logged)

# ---- resolution steps 2..14 -------------------------------------------------

proc spawnSources(sim: Sim) =
  ## Step 2, first half.
  let tick = sim.tick
  if tick mod sim.config.sourceSpawnPeriod == 0 and
      sim.sources.orbitsAlive() < sim.config.maxOrbits:
    let cells = drawOrbitCells(sim.sources, sim.meadow, sim.rng,
      sim.config.minNestClearance)
    if cells.len == Colonies:
      var payload = newJArray()
      var near = newJArray()
      let orbit = sim.sources.nextOrbit
      sim.sources.nextOrbit.inc
      for cell in cells:
        let index = sim.sources.addSource(sim.meadow, cell.cx, cell.cy,
          sim.config.sourceAmount, tick, sim.config.sourceLifeTicks, false)
        payload.add(%*{
          "id": int(sim.sources.items[index].id),
          "cell": [cell.cx, cell.cy],
          "amount": sim.config.sourceAmount
        })
        let nest = nearestNest(sim.meadow, cell.cx, cell.cy,
          sim.config.raidRadius)
        near.add(if nest >= 0: %sim.meadow.nests[nest].alias else: newJNull())
      var event = sourceSpawn(tick, "orbit", orbit, payload)
      event["near"] = near
      if sim.recording:
        sim.events.add(event)

  if tick in sim.config.bonanzaTicks:
    var payload = newJArray()
    var near = newJArray()
    for cell in sim.meadow.bonanzaCells:
      let index = sim.sources.addSource(sim.meadow, cell.cx, cell.cy,
        sim.config.bonanzaAmount, tick, sim.config.bonanzaLifeTicks, true)
      payload.add(%*{
        "id": int(sim.sources.items[index].id),
        "cell": [cell.cx, cell.cy],
        "amount": sim.config.bonanzaAmount
      })
      near.add(newJNull())
    var event = sourceSpawn(tick, "bonanza", -1, payload)
    event["near"] = near
    if sim.recording:
      sim.events.add(event)

proc retireSources(sim: Sim) =
  ## Step 2, second half: ascending source id.
  let tick = sim.tick
  for index in 0 ..< sim.sources.items.len:
    if not sim.sources.items[index].alive:
      continue
    let item = sim.sources.items[index]
    let expired = tick - int(item.spawnTick) >= int(item.lifeTicks)
    if item.amount > 0'i32 and not expired:
      continue
    var taken = newJArray()
    for seat in 0 ..< Colonies:
      taken.add(%int(sim.sources.taken[index][sim.seatNest[seat]]))
    if sim.recording:
      sim.events.add(sourceGone(tick, int(item.id), int(item.cx),
        int(item.cy),
        (if item.amount <= 0'i32: "depleted" else: "expired"), taken))
    sim.sources.retire(sim.meadow, index)

proc noteSightings(sim: Sim, colony, cx, cy: int) =
  ## `sources[]` in the view lists only caches one of your ants has been
  ## within one cell of, at the amount it had WHEN SEEN.
  let want = sim.sources.items.len
  if sim.seenAmount[colony].len < want:
    let had = sim.seenAmount[colony].len
    sim.seenAmount[colony].setLen(want)
    sim.seenTurn[colony].setLen(want)
    for index in had ..< want:
      sim.seenAmount[colony][index] = 0
      sim.seenTurn[colony][index] = -1
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      let index = sim.sources.sourceAt(sim.meadow, cx + dx, cy + dy)
      if index >= 0:
        sim.seenAmount[colony][index] = int(sim.sources.items[index].amount)
        sim.seenTurn[colony][index] = sim.turn

proc runAnts(sim: Sim) =
  ## Steps 3 through 9.
  let stride = sim.config.antStepTicks
  let perColony = sim.config.antsPerColony
  let tick = sim.tick
  for g in 0 ..< sim.antsTotal():
    if (tick + g) mod stride != 0:
      continue
    let colony = g div perColony
    let coefficient = sim.coefficients[colony]
    let doctrine = sim.doctrines[colony]
    let kernel = sim.colonyKernel(colony)
    let inOwnPad = sim.meadow.inNestPad(colony,
      int(sim.antState[g].cx), int(sim.antState[g].cy))

    ## Step 4: the recall modifier.
    let recalled = doctrine.recall
    if recalled and inOwnPad:
      sim.antState[g].held = true
      continue

    sim.noteSightings(colony, int(sim.antState[g].cx), int(sim.antState[g].cy))

    ## Step 5: deposit, then stamp the sensed block.
    if not recalled:
      let cx = int(sim.antState[g].cx)
      let cy = int(sim.antState[g].cy)
      if sim.antState[g].carrying:
        sim.planes.deposit(colony, PlaneFood, cx, cy, coefficient.layFood,
          sim.config.pheromoneMax)
      else:
        sim.planes.deposit(colony, PlaneHome, cx, cy, coefficient.layHome,
          sim.config.pheromoneMax)
      sim.sensed[colony][blockOf(cx, cy)] = sim.turn

    var skipMove = false

    ## Step 6: pickup. Own cell first, then N, NE, E, SE, S, SW, W, NW.
    if not sim.antState[g].carrying:
      let cx = int(sim.antState[g].cx)
      let cy = int(sim.antState[g].cy)
      var pick = sim.sources.sourceAt(sim.meadow, cx, cy)
      if pick >= 0 and sim.sources.items[pick].amount <= 0'i32:
        pick = -1
      if pick < 0:
        for k in 0 .. 7:
          let candidate = sim.sources.sourceAt(sim.meadow,
            cx + ScanX[k], cy + ScanY[k])
          if candidate >= 0 and sim.sources.items[candidate].amount > 0'i32:
            if pick < 0 or
                sim.sources.items[candidate].id < sim.sources.items[pick].id:
              pick = candidate
      if pick >= 0:
        sim.sources.takeUnit(sim.meadow, pick, colony)
        sim.harvested[colony].inc
        sim.antState[g].carrying = true
        sim.antState[g].carriedFrom = sim.sources.items[pick].id
        sim.antState[g].heading = int32((int(sim.antState[g].heading) + 4) and 7)
        skipMove = true

    ## Step 7: delivery, into the ant's OWN pad only.
    var delivered = false
    if sim.antState[g].carrying and not skipMove and inOwnPad:
      sim.delivered[colony].inc
      sim.antState[g].carrying = false
      let sourceId = int(sim.antState[g].carriedFrom)
      var raid = 0
      var victim = -1
      if sourceId >= 0 and sourceId < sim.sources.items.len:
        victim = nearestNest(sim.meadow, int(sim.sources.items[sourceId].cx),
          int(sim.sources.items[sourceId].cy), sim.config.raidRadius)
        if victim >= 0 and victim != colony:
          raid = 1
          sim.raidedUnits[colony].inc
          sim.raidedFromYou[victim].inc
          if sim.recording:
            sim.events.add(raidEvent(tick, sim.meadow.nests[colony].alias,
              sim.meadow.nests[victim].alias, sourceId,
              sim.raidedUnits[colony]))
      if sim.recording:
        sim.events.add(deliverEvent(tick, sim.seatOfNest(colony),
          sim.delivered[colony], sourceId, raid))
      sim.antState[g].carriedFrom = -1'i32
      delivered = true
      skipMove = true

    ## Step 8: move.
    var moved = false
    if not skipMove:
      let beforeX = sim.antState[g].cx
      let beforeY = sim.antState[g].cy
      moveAnt(sim.antState[g], sim.meadow, sim.planes, sim.sources.foodNear,
        colony, kernel, coefficient, sim.rng, recalled)
      moved = sim.antState[g].cx != beforeX or sim.antState[g].cy != beforeY

    ## Step 9: release.
    if recalled:
      continue
    let standing = sim.meadow.inNestPad(colony, int(sim.antState[g].cx),
      int(sim.antState[g].cy))
    if delivered or (standing and not sim.antState[g].carrying and not moved):
      let focusCx = doctrine.focusBx * BlockCells + BlockCells div 2
      let focusCy = doctrine.focusBy * BlockCells + BlockCells div 2
      sim.antState[g].heading = int32(releaseHeading(sim.rng,
        doctrine.focusWeight, doctrine.hasFocus,
        sim.meadow.nests[colony].cx, sim.meadow.nests[colony].cy,
        focusCx, focusCy))

proc scanContacts(sim: Sim) =
  ## The `contacts[]` half of the view: blocks where one colony's ants shared a
  ## cell with a rival's. Sampled on a fixed cadence; deterministic either way.
  let perColony = sim.config.antsPerColony
  for g in 0 ..< sim.antsTotal():
    let colony = g div perColony
    let cx = int(sim.antState[g].cx)
    let cy = int(sim.antState[g].cy)
    for other in 0 ..< Colonies:
      if other == colony:
        continue
      var shared = false
      for h in other * perColony ..< (other + 1) * perColony:
        if sim.antState[h].cx == int32(cx) and sim.antState[h].cy == int32(cy):
          shared = true
          break
      if shared:
        sim.contactCount[colony][other][blockOf(cx, cy)].inc
        sim.contactAnts[colony][other][g mod perColony] = true

proc scanTrailWars(sim: Sim) =
  ## Step 10.
  for by in 0 ..< BlockRows:
    for bx in 0 ..< BlockCols:
      var hot = newJArray()
      var strengths = newJArray()
      var count = 0
      for colony in 0 ..< Colonies:
        let mean = sim.planes.blockMean(colony, PlaneFood, bx, by)
        if mean > sim.config.trailWarThreshold:
          inc count
          hot.add(%sim.meadow.nests[colony].alias)
          strengths.add(%mean)
      if count >= 2:
        if sim.recording:
          sim.events.add(trailWar(sim.tick, bx, by, hot, strengths))

proc flushHarvest(sim: Sim) =
  ## Step 12.
  for bucket in sim.sources.buckets:
    if bucket.units == 0'i32:
      continue
    if sim.recording:
      sim.events.add(harvestEvent(sim.tick, int(bucket.source),
        sim.seatOfNest(int(bucket.colony)), int(bucket.units)))
  sim.sources.buckets.setLen(0)

proc antStateCode*(sim: Sim, g: int): uint8 =
  if sim.antState[g].held: AntStateHeld
  elif sim.antState[g].carrying: AntStateCarrying
  elif sim.antState[g].scout: AntStateScout
  else: AntStateForager

proc appendKeyframe(sim: Sim) =
  ## Step 13.
  var delivered = newJArray()
  var carrying = newJArray()
  for seat in 0 ..< Colonies:
    let colony = sim.seatNest[seat]
    delivered.add(%sim.delivered[colony])
    var count = 0
    for index in 0 ..< sim.config.antsPerColony:
      if sim.antState[colony * sim.config.antsPerColony + index].carrying:
        inc count
    carrying.add(%count)
  var live = newJArray()
  for item in sim.sources.items:
    if item.alive:
      live.add(%[int(item.id), int(item.cx), int(item.cy), int(item.amount)])
  let digest = sim.hiveStateDigest()
  sim.lastDigest = digest
  sim.lastDigestTick = sim.tick
  sim.lastKeyframeAnts.setLen(0)
  for g in 0 ..< sim.antsTotal():
    sim.lastKeyframeAnts.add(uint8(sim.antState[g].cx))
    sim.lastKeyframeAnts.add(uint8(sim.antState[g].cy))
    sim.lastKeyframeAnts.add(sim.antStateCode(g))
  if not sim.recording:
    return
  sim.keyframes.add(%*{
    "t": sim.tick,
    # int64: the u32 digest does not fit a wasm32 `int`, and the viewer
    # re-reads this exact value with getBiggestInt.
    "d": int64(digest),
    "del": delivered,
    "car": carrying,
    "src": live
  })
  for value in sim.lastKeyframeAnts:
    sim.antBytes.add(value)
  sim.keyframeCount.inc
  for colony in 0 ..< Colonies:
    let peak = sim.planes.peakFood(colony)
    if peak > sim.peakFoodTrail[colony]:
      sim.peakFoodTrail[colony] = peak

proc stepTick*(sim: Sim) =
  ## One tick, resolution steps 2 through 14. Step 1 is `installDoctrines`
  ## and step 15 lives in the driver, which owns the wall clock.
  if sim.tick mod sim.config.turnTicks == 0:
    ## Step 14, taken at the TOP of the turn so a backward seek can resume
    ## from it and replay at most `turnTicks` ticks. Indexed by turn, so a
    ## viewer that re-runs a stretch does not grow the snapshot list.
    let turnIndex = sim.tick div sim.config.turnTicks
    if sim.snapshots.len == turnIndex:
      sim.snapshots.add(sim.takeSnapshot())
  sim.spawnSources()
  sim.retireSources()
  sim.runAnts()
  if sim.tick mod 4 == 0:
    sim.scanContacts()
  if sim.tick mod TrailWarPeriod == 0:
    sim.scanTrailWars()
  if sim.tick mod sim.config.decayPeriodTicks == 0:
    sim.planes.decay(sim.config.pheromoneDecayNum, sim.config.pheromoneFloor)
  if sim.tick mod HarvestPeriod == 0:
    sim.flushHarvest()
  if sim.tick mod KeyframePeriod == 0:
    sim.appendKeyframe()
  sim.tick.inc

