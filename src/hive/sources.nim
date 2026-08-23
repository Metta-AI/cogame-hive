## Food sources: symmetric orbits, the two centre bonanzas, depletion, expiry
## and the 24-tick harvest buckets.
##
## New in hive. Sources appear in mirror-symmetric sets so no colony is ever
## handed a closer meadow than another.

import types, field

type
  Harvest* = object
    source*: int32
    colony*: int32
    units*: int32

  SourceSet* = object
    items*: seq[Source]
    at*: seq[int32]        ## cell -> index into `items`, -1 when empty
    foodNear*: seq[int16]  ## 3x3 coverage counts, read by the ant kernel
    nextId*: int32
    spawned*: int
    nextOrbit*: int
    taken*: seq[array[Colonies, int32]]  ## per source, per colony, units lifted
    buckets*: seq[Harvest]

proc initSourceSet*(cols, rows: int): SourceSet =
  result.at = newSeq[int32](cols * rows)
  for index in 0 ..< result.at.len:
    result.at[index] = -1'i32
  result.foodNear = newSeq[int16](cols * rows)

proc coverNear(sources: var SourceSet, meadow: Field, cx, cy, delta: int) =
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      let nx = cx + dx
      let ny = cy + dy
      if meadow.onField(nx, ny):
        sources.foodNear[ny * meadow.cols + nx] += int16(delta)

proc addSource*(
  sources: var SourceSet,
  meadow: Field,
  cx, cy, amount, spawnTick, lifeTicks: int,
  bonanza: bool
): int =
  ## Appends one live source and returns its index in `items`.
  result = sources.items.len
  sources.items.add(Source(
    id: sources.nextId,
    cx: int32(cx),
    cy: int32(cy),
    amount: int32(amount),
    spawnAmount: int32(amount),
    spawnTick: int32(spawnTick),
    lifeTicks: int32(lifeTicks),
    alive: true,
    bonanza: bonanza
  ))
  sources.taken.add(default(array[Colonies, int32]))
  sources.nextId.inc
  sources.spawned.inc
  sources.at[cy * meadow.cols + cx] = int32(result)
  sources.coverNear(meadow, cx, cy, 1)

proc retire*(sources: var SourceSet, meadow: Field, index: int) =
  if not sources.items[index].alive:
    return
  sources.items[index].alive = false
  let cx = int(sources.items[index].cx)
  let cy = int(sources.items[index].cy)
  sources.at[cy * meadow.cols + cx] = -1'i32
  if sources.items[index].amount > 0'i32:
    sources.coverNear(meadow, cx, cy, -1)

proc takeUnit*(sources: var SourceSet, meadow: Field, index, colony: int) =
  ## One unit off a live source; the last unit clears its scent immediately.
  sources.items[index].amount -= 1'i32
  sources.taken[index][colony] += 1'i32
  if sources.items[index].amount == 0'i32:
    sources.coverNear(meadow,
      int(sources.items[index].cx), int(sources.items[index].cy), -1)
  var found = false
  for bucket in sources.buckets.mitems:
    if bucket.source == sources.items[index].id and
        bucket.colony == int32(colony):
      bucket.units += 1'i32
      found = true
      break
  if not found:
    sources.buckets.add(Harvest(source: sources.items[index].id,
      colony: int32(colony), units: 1'i32))

proc liveCount*(sources: SourceSet): int =
  for item in sources.items:
    if item.alive:
      inc result

proc orbitsAlive*(sources: SourceSet): int =
  ## An orbit is four sources; a partially eaten orbit still counts while any
  ## of its members is alive, so counting non-bonanza survivors in quarters is
  ## wrong. Orbits are tracked by the count of live non-bonanza sources
  ## rounded up - four to an orbit.
  var live = 0
  for item in sources.items:
    if item.alive and not item.bonanza:
      inc live
  (live + Colonies - 1) div Colonies

proc sourceAt*(sources: SourceSet, meadow: Field, cx, cy: int): int {.inline.} =
  if not meadow.onField(cx, cy): -1
  else: int(sources.at[cy * meadow.cols + cx])

proc clearanceOk(
  sources: SourceSet,
  meadow: Field,
  cx, cy, minNestClearance: int
): bool =
  if not meadow.isFree(cx, cy):
    return false
  for nest in 0 ..< Colonies:
    if chebyshev(cx, cy, meadow.nests[nest].cx, meadow.nests[nest].cy) <
        minNestClearance:
      return false
  for item in sources.items:
    if item.alive and chebyshev(cx, cy, int(item.cx), int(item.cy)) < 3:
      return false
  true

proc mirrorCells*(meadow: Field, cx, cy: int): array[Colonies, tuple[cx, cy: int]] =
  ## The cell and its three mirror images, in a fixed order.
  let mx = meadow.cols - 1 - cx
  let my = meadow.rows - 1 - cy
  [(cx: cx, cy: cy), (cx: mx, cy: cy), (cx: cx, cy: my), (cx: mx, cy: my)]

proc drawOrbitCells*(
  sources: SourceSet,
  meadow: Field,
  rng: var Pcg,
  minNestClearance: int
): seq[tuple[cx, cy: int]] =
  ## Draws one orbit: a cell inside the top-left spawn quadrant plus its three
  ## mirror images. Up to 64 tries, then the spawn is skipped. Always draws
  ## exactly two values per try so the stream stays a function of the seed.
  let loX = meadow.spawnQuadrant[0]
  let loY = meadow.spawnQuadrant[1]
  let hiX = meadow.spawnQuadrant[2]
  let hiY = meadow.spawnQuadrant[3]
  for attempt in 0 ..< 64:
    let cx = loX + rng.rnd(hiX - loX + 1)
    let cy = loY + rng.rnd(hiY - loY + 1)
    let cells = mirrorCells(meadow, cx, cy)
    var ok = true
    for cell in cells:
      if not sources.clearanceOk(meadow, cell.cx, cell.cy, minNestClearance):
        ok = false
        break
    if ok:
      return @cells
  @[]

proc nearestNest*(meadow: Field, cx, cy, raidRadius: int): int =
  ## The colony whose nest centre is within `raidRadius` Chebyshev cells, or
  ## -1. Ties go to the lowest nest index.
  result = -1
  var best = raidRadius + 1
  for nest in 0 ..< Colonies:
    let distance = chebyshev(cx, cy, meadow.nests[nest].cx, meadow.nests[nest].cy)
    if distance <= raidRadius and distance < best:
      best = distance
      result = nest
