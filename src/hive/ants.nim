## The ant kernel: three candidate cells, one integer score each, the highest
## wins, ties break left-forward-right. Identical for every ant of every
## colony; the only things that change are the coefficients the colony's
## doctrine compiles to.
##
## New in hive. Every operation is integer - no `sin`, `cos`, `sqrt`, `pow`,
## `exp`, `ln`, `fmod`, `hypot` or float arithmetic of any kind appears here,
## which is what makes the emscripten build reproduce the native digest.

import types, field, pheromones

type
  Kernel* = object
    ## Everything the kernel reads that is not the ant itself.
    cap*: int
    nestSense*: int
    nestCx*: int
    nestCy*: int

proc candidateDirs*(heading: int): array[3, int] {.inline.} =
  ## Forward-left, forward, forward-right - and that is also the tie order.
  [(heading + 7) and 7, heading, (heading + 1) and 7]

proc foodAdjacent*(foodNear: seq[int16], cols, cx, cy: int): int {.inline.} =
  if foodNear[cy * cols + cx] > 0'i16: 1 else: 0

proc searchScore*(
  planes: Planes,
  foodNear: seq[int16],
  colony, cx, cy: int,
  coefficients: Coefficients,
  scout: bool,
  forward: bool,
  noise: int
): int =
  let alphaFood =
    if scout: coefficients.alphaFood div 4 else: coefficients.alphaFood
  let alphaRival = if scout: 0 else: coefficients.alphaRival
  result = (alphaFood * planes.get(colony, PlaneFood, cx, cy)) shr 4
  result += (alphaRival * planes.rivalFoodMax(colony, cx, cy)) shr 4
  result -= (coefficients.alphaHome * planes.get(colony, PlaneHome, cx, cy)) shr 4
  if forward:
    result += coefficients.alphaFwd
  result += AlphaScent * foodAdjacent(foodNear, planes.cols, cx, cy)
  result += noise

proc carryScore*(
  planes: Planes,
  colony, cx, cy: int,
  fromCx, fromCy: int,
  kernel: Kernel,
  coefficients: Coefficients,
  forward: bool,
  noise: int
): int =
  result = (coefficients.betaHome * planes.get(colony, PlaneHome, cx, cy)) shr 4
  ## Path integration is deliberately short-ranged: beyond `nestSense` cells a
  ## laden ant has no idea where home is and must ride the home trail its
  ## nestmates laid.
  let here = chebyshev(fromCx, fromCy, kernel.nestCx, kernel.nestCy)
  if here <= kernel.nestSense and
      chebyshev(cx, cy, kernel.nestCx, kernel.nestCy) < here:
    result += BetaNest
  if forward:
    result += BetaFwd
  result += noise

proc moveAnt*(
  ant: var Ant,
  meadow: Field,
  planes: Planes,
  foodNear: seq[int16],
  colony: int,
  kernel: Kernel,
  coefficients: Coefficients,
  rng: var Pcg,
  recalled = false
) =
  ## One activation's movement. Draws exactly three noise values first, in
  ## candidate order, so the draw count per activation is constant whatever
  ## the terrain does.
  ##
  ## `recalled` is resolution step 4: a recalled ant runs the CARRYING kernel
  ## regardless of its carrying flag, so it walks home on the home trail
  ## instead of being repelled by it (`searchScore` subtracts alphaHome).
  let dirs = candidateDirs(int(ant.heading))
  let carrying = ant.carrying or recalled
  var noise: array[3, int]
  for k in 0 .. 2:
    noise[k] =
      if carrying: rng.rnd(CarryNoise)
      elif ant.scout: rng.rnd(coefficients.alphaNoise * 2)
      else: rng.rnd(coefficients.alphaNoise)

  var bestScore = low(int)
  var bestIndex = -1
  for k in 0 .. 2:
    let nx = int(ant.cx) + DirX[dirs[k]]
    let ny = int(ant.cy) + DirY[dirs[k]]
    if not meadow.isFree(nx, ny):
      continue
    let forward = k == 1
    let score =
      if carrying:
        carryScore(planes, colony, nx, ny, int(ant.cx), int(ant.cy),
          kernel, coefficients, forward, noise[k])
      else:
        searchScore(planes, foodNear, colony, nx, ny, coefficients,
          ant.scout, forward, noise[k])
    if score > bestScore:
      bestScore = score
      bestIndex = k

  if bestIndex < 0:
    ## Boxed in on all three candidates: turn 90 degrees and stay put. The
    ## single-4-connected-component invariant on the free floor is what
    ## guarantees this terminates.
    ant.heading = int32((int(ant.heading) + 2) and 7)
    return
  let dir = dirs[bestIndex]
  ant.cx = int32(int(ant.cx) + DirX[dir])
  ant.cy = int32(int(ant.cy) + DirY[dir])
  ant.heading = int32(dir)

proc bearingTo*(fromCx, fromCy, toCx, toCy: int): int =
  ## The one of eight headings best matching a bearing, chosen by integer dot
  ## product - no `atan2`, no float.
  let dx = toCx - fromCx
  let dy = toCy - fromCy
  if dx == 0 and dy == 0:
    return 0
  var best = 0
  var bestScore = low(int)
  for d in 0 .. 7:
    ## Scale the diagonal unit vectors by 3/4 so the eight comparisons are
    ## commensurate in integers (3/4 ~= 0.707 to within 6%).
    let vx = DirX[d] * (if DirX[d] != 0 and DirY[d] != 0: 3 else: 4)
    let vy = DirY[d] * (if DirX[d] != 0 and DirY[d] != 0: 3 else: 4)
    let score = dx * vx + dy * vy
    if score > bestScore:
      bestScore = score
      best = d
  best

proc releaseHeading*(
  rng: var Pcg,
  focusWeight: int,
  hasFocus: bool,
  nestCx, nestCy, focusCx, focusCy: int
): int =
  ## Step 9. The only colony-level steering that exists, and it acts at the
  ## nest mouth on a departing body - never on an ant in the field.
  let roll = rng.rnd(100)
  let uniform = rng.rnd(8)
  if hasFocus and roll < focusWeight:
    bearingTo(nestCx, nestCy, focusCx, focusCy)
  else:
    uniform
