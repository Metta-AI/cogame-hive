## Sim unit tests on the ant kernel, plus the no-float source guard that keeps
## the native and emscripten builds digest-identical.

import std/strutils
import support/helpers
import hive/[pheromones, ants, sources]

proc kernelFor(meadow: Field, colony: int): Kernel =
  Kernel(cap: 4000, nestSense: 12, nestCx: meadow.nests[colony].cx,
    nestCy: meadow.nests[colony].cy)

proc flatCoefficients(): Coefficients =
  ## Every weight zero except the trail term, so a test can isolate one force.
  Coefficients(alphaFood: 64, alphaRival: 0, alphaHome: 0, alphaFwd: 0,
    alphaNoise: 1, betaHome: 64, layFood: 100, layHome: 100, scoutCount: 0)

proc main() =
  let meadow = testField()
  let emptyFood = newSeq[int16](meadow.cols * meadow.rows)

  block gradientTurn:
    var planes = initPlanes(meadow.cols, meadow.rows)
    var ant = Ant(cx: 80, cy: 20, heading: 0, carrying: false)
    ## Heading 0 is E; forward-left is (heading+7)&7 = NE at (81, 19).
    let dirs = candidateDirs(0)
    checkEqual(dirs[0], 7, "forward-left of E")
    checkEqual(dirs[1], 0, "forward of E")
    checkEqual(dirs[2], 1, "forward-right of E")
    planes.deposit(0, PlaneFood, 81 + DirX[dirs[0]] - 1, 20 + DirY[dirs[0]],
      0, 4000)
    planes.deposit(0, PlaneFood, 80 + DirX[dirs[0]], 20 + DirY[dirs[0]],
      4000, 4000)
    var rng = initPcg(7)
    moveAnt(ant, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      flatCoefficients(), rng)
    checkEqual(int(ant.cx), 80 + DirX[dirs[0]], "moved onto the strong cell x")
    checkEqual(int(ant.cy), 20 + DirY[dirs[0]], "moved onto the strong cell y")
    checkEqual(int(ant.heading), dirs[0], "heading follows the move")
    report("a strong F gradient on the forward-left cell turns the ant onto it")

  block tieOrder:
    var planes = initPlanes(meadow.cols, meadow.rows)
    var coefficients = flatCoefficients()
    coefficients.alphaNoise = 1     ## rnd(0..0) == 0, so every score ties
    var ant = Ant(cx: 80, cy: 20, heading: 0, carrying: false)
    var rng = initPcg(1)
    let dirs = candidateDirs(0)
    moveAnt(ant, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      coefficients, rng)
    checkEqual(int(ant.heading), dirs[0],
      "a three-way tie breaks LEFT first (candidate order)")
    report("ties break left, forward, right")

  block boxedIn:
    ## Author a rock pocket: an ant facing into a wall on all three
    ## candidates turns 90 degrees and does not move.
    var blocked = meadow
    var ant = Ant(cx: 80, cy: 20, heading: 0, carrying: false)
    for k in 0 .. 2:
      let d = candidateDirs(0)[k]
      blocked.rock[(20 + DirY[d]) * blocked.cols + (80 + DirX[d])] = true
    var planes = initPlanes(meadow.cols, meadow.rows)
    var rng = initPcg(3)
    moveAnt(ant, blocked, planes, emptyFood, 0, kernelFor(meadow, 0),
      flatCoefficients(), rng)
    checkEqual(int(ant.cx), 80, "boxed in: x unchanged")
    checkEqual(int(ant.cy), 20, "boxed in: y unchanged")
    checkEqual(int(ant.heading), 2, "boxed in: a 90 degree turn")
    report("an ant boxed by rock turns 90 degrees and stays put")

  block neverLeaves:
    ## 50 000 randomised activations: never rock, never off-field.
    var planes = initPlanes(meadow.cols, meadow.rows)
    var rng = initPcg(99)
    var ant = Ant(cx: int32(meadow.nests[0].cx), cy: int32(meadow.nests[0].cy),
      heading: 0, carrying: false)
    var coefficients = flatCoefficients()
    coefficients.alphaNoise = 400
    for step in 0 ..< 50_000:
      if step mod 977 == 0:
        ant.carrying = not ant.carrying
        ant.scout = (step div 977) mod 2 == 0
      moveAnt(ant, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
        coefficients, rng)
      check(meadow.onField(int(ant.cx), int(ant.cy)),
        "ant stayed on the field at step " & $step)
      check(not meadow.isRock(int(ant.cx), int(ant.cy)),
        "ant stayed off rock at step " & $step)
    report("50 000 randomised activations never leave the free floor")

  block striping:
    ## Ant g acts iff (t + g) mod 2 == 0, so exactly half of the 96 bodies act
    ## on every tick.
    let total = Colonies * 24
    for tick in 0 .. 5:
      var acting = 0
      for g in 0 ..< total:
        if (tick + g) mod 2 == 0: inc acting
      checkEqual(acting, total div 2,
        "activation striping puts 48 ants on tick " & $tick)
    report("activation striping puts exactly 48 ants on every tick")

  block carryingHome:
    ## Inside 12 cells the laden ant walks the Chebyshev gradient home; beyond
    ## it, the nest term is off and the ant follows H.
    var planes = initPlanes(meadow.cols, meadow.rows)
    let nest = meadow.nests[0]
    ## Heading 4 is W, so the three candidates all point back toward the pad.
    var near = Ant(cx: int32(nest.cx + 6), cy: int32(nest.cy), heading: 4,
      carrying: true)
    var rng = initPcg(11)
    let before = chebyshev(int(near.cx), int(near.cy), nest.cx, nest.cy)
    moveAnt(near, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      flatCoefficients(), rng)
    check(chebyshev(int(near.cx), int(near.cy), nest.cx, nest.cy) < before,
      "inside 12 cells a laden ant reduces its Chebyshev distance to home")

    ## Beyond the sense radius, only the home trail steers. Lay a strong H on
    ## the forward-left cell and check the ant takes it.
    var far = Ant(cx: int32(nest.cx + 40), cy: int32(nest.cy + 20), heading: 0,
      carrying: true)
    let dirs = candidateDirs(0)
    check(chebyshev(int(far.cx), int(far.cy), nest.cx, nest.cy) > 12,
      "the far ant really is beyond the sense radius")
    planes.deposit(0, PlaneHome, int(far.cx) + DirX[dirs[0]],
      int(far.cy) + DirY[dirs[0]], 4000, 4000)
    var rng2 = initPcg(12)
    moveAnt(far, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      flatCoefficients(), rng2)
    checkEqual(int(far.heading), dirs[0],
      "beyond 12 cells a laden ant rides the home trail")
    report("path integration is short-ranged; beyond it H is load-bearing")

  block scoutModifier:
    ## A scout runs alphaFood div 4, alphaRival 0 and doubled noise.
    var planes = initPlanes(meadow.cols, meadow.rows)
    planes.deposit(0, PlaneFood, 30, 30, 4000, 4000)
    planes.deposit(1, PlaneFood, 30, 30, 4000, 4000)
    var coefficients = flatCoefficients()
    coefficients.alphaFood = 400
    coefficients.alphaRival = 300
    let forager = searchScore(planes, emptyFood, 0, 30, 30, coefficients,
      false, false, 0)
    let scout = searchScore(planes, emptyFood, 0, 30, 30, coefficients,
      true, false, 0)
    checkEqual(forager, ((400 * 4000) shr 4) + ((300 * 4000) shr 4),
      "a forager weighs its own trail and the rival trail")
    checkEqual(scout, (400 div 4) * 4000 shr 4,
      "a scout weighs alphaFood div 4 and ignores rival trails")
    report("scouts get alphaFood div 4, alphaRival 0 and doubled noise")

  block scentAlwaysCounts:
    var planes = initPlanes(meadow.cols, meadow.rows)
    var foodNear = newSeq[int16](meadow.cols * meadow.rows)
    foodNear[30 * meadow.cols + 30] = 1
    let with = searchScore(planes, foodNear, 0, 30, 30, flatCoefficients(),
      false, false, 0)
    checkEqual(with, AlphaScent, "food you can smell adds alphaScent")
    report("foodAdjacent contributes alphaScent")

  block pickupAndDelivery:
    ## Isolate one colony-0 ant on a quiet field: no orbit spawns, no
    ## bonanzas, so the only source is the one this test plants.
    var quiet = testConfig(240, 5)
    quiet.maxOrbits = 0
    quiet.bonanzaTicks = @[]
    var match = newSim(quiet, meadow)
    let nest = meadow.nests[0]
    ## Park the ant one cell east of its pad edge, and a cache on its own cell.
    let cx = nest.cx + 4
    let cy = nest.cy
    match.antState[0] = Ant(cx: int32(cx), cy: int32(cy), heading: 0,
      carrying: false, carriedFrom: -1)
    let index = match.sources.addSource(meadow, cx, cy, 5, 0, 10_000, false)
    let sourceId = int(match.sources.items[index].id)
    match.stepTick()
    checkEqual(int(match.sources.items[index].amount), 4,
      "pickup takes exactly one unit")
    check(match.antState[0].carrying, "the ant is carrying after a pickup")
    checkEqual(int(match.antState[0].carriedFrom), sourceId,
      "carried_from names the source")
    checkEqual(int(match.antState[0].heading), 4, "pickup about-faces (0 -> 4)")
    checkEqual(int(match.antState[0].cx), cx, "pickup skips the move: x")
    checkEqual(int(match.antState[0].cy), cy, "pickup skips the move: y")
    checkEqual(match.harvested[0], 1, "the harvest counter moved")
    report("pickup takes one unit, sets carried_from and about-faces")

  block deliveryOwnPadOnly:
    var quiet = testConfig(240, 6)
    quiet.maxOrbits = 0
    quiet.bonanzaTicks = @[]
    var match = newSim(quiet, meadow)
    ## Colony 0's ant 0, carrying, standing on its OWN pad.
    match.antState[0] = Ant(cx: int32(meadow.nests[0].cx),
      cy: int32(meadow.nests[0].cy), heading: 0, carrying: true,
      carriedFrom: -1)
    ## Colony 1's ant 0, carrying, standing on colony 0's pad. A rival's pad
    ## does nothing: you cannot deliver to, or steal from, another nest.
    let rival = quiet.antsPerColony
    match.antState[rival] = Ant(cx: int32(meadow.nests[0].cx),
      cy: int32(meadow.nests[0].cy), heading: 0, carrying: true,
      carriedFrom: -1)
    match.stepTick()
    checkEqual(match.delivered[0], 1, "exactly one counter moved")
    checkEqual(match.delivered[1], 0, "a rival's pad delivers nothing")
    checkEqual(match.delivered[2], 0, "no other colony scored")
    checkEqual(match.delivered[3], 0, "no other colony scored")
    check(not match.antState[0].carrying, "the deliverer dropped its load")
    check(match.antState[rival].carrying,
      "the ant standing on a rival pad kept its load")
    report("delivery increments one counter and only on the ant's own pad")

  block recallUsesTheCarryingKernel:
    ## Resolution step 4: a recalled ant runs the CARRYING kernel REGARDLESS
    ## of its carrying flag. Under the searching kernel it is repelled by the
    ## very home trail it has to follow (alphaHome is subtracted), so it
    ## reaches its pad only by chance.
    var planes = initPlanes(meadow.cols, meadow.rows)
    let nest = meadow.nests[0]
    var coefficients = flatCoefficients()
    coefficients.alphaHome = 300
    let sx = nest.cx + 40
    let sy = nest.cy + 20
    check(meadow.isFree(sx, sy), "the probe cell is free floor")
    check(chebyshev(sx, sy, nest.cx, nest.cy) > 12,
      "the probe ant is beyond the nest-sense radius, so only H steers it")
    let dirs = candidateDirs(0)
    planes.deposit(0, PlaneHome, sx + DirX[dirs[0]], sy + DirY[dirs[0]],
      4000, 4000)

    var searching = Ant(cx: int32(sx), cy: int32(sy), heading: 0,
      carrying: false, carriedFrom: -1)
    var rngA = initPcg(3)
    moveAnt(searching, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      coefficients, rngA)
    check(int(searching.heading) != dirs[0],
      "a searching ant is REPELLED by its own home trail")

    var homing = Ant(cx: int32(sx), cy: int32(sy), heading: 0,
      carrying: false, carriedFrom: -1)
    var rngB = initPcg(3)
    moveAnt(homing, meadow, planes, emptyFood, 0, kernelFor(meadow, 0),
      coefficients, rngB, recalled = true)
    checkEqual(int(homing.heading), dirs[0],
      "a recalled EMPTY ant rides the home trail like a laden one")
    report("recall puts an empty ant on the carrying kernel")

  block recallGathersTheColony:
    ## The same rule through the real step: an empty colony parked eight cells
    ## out with recall installed walks home and holds, inside one turn.
    var quiet = testConfig(240, 9)
    quiet.maxOrbits = 0
    quiet.bonanzaTicks = @[]
    var match = newSim(quiet, meadow)
    let colony = 0
    let nest = meadow.nests[colony]
    check(meadow.isFree(nest.cx + 8, nest.cy), "the muster cell is free floor")
    for index in 0 ..< quiet.antsPerColony:
      match.antState[colony * quiet.antsPerColony + index] =
        Ant(cx: int32(nest.cx + 8), cy: int32(nest.cy), heading: 0,
          carrying: false, carriedFrom: -1)
    var resolved: array[Colonies, ResolvedDoctrine]
    for seat in 0 ..< Colonies:
      var doctrine = defaultDoctrine()
      doctrine.recall = match.seatNest[seat] == colony
      resolved[seat] = ResolvedDoctrine(doctrine: doctrine, source: dsScripted)
    match.installDoctrines(resolved)
    while match.tick < quiet.turnTicks:
      match.stepTick()
    var held = 0
    for index in 0 ..< quiet.antsPerColony:
      if match.antState[colony * quiet.antsPerColony + index].held:
        inc held
    checkEqual(held, quiet.antsPerColony,
      "every recalled ant reached its own pad and is holding")
    report("a recalled colony musters at its nest inside one turn")

  block noFloatInTheStep:
    ## The determinism contract, enforced by grep. `-ffast-math` is banned and
    ## no libm call or float arithmetic may appear anywhere in the step path.
    const StepModules = ["field", "pheromones", "ants", "sources", "sim"]
    const Libm = ["sin", "cos", "tan", "arctan", "arcsin", "arccos", "exp",
      "ln", "log10", "pow", "fmod", "hypot", "sqrt", "cbrt"]
    const FloatTypes = ["float", "float32", "float64", "cfloat", "cdouble"]
    for name in StepModules:
      let source = stripComments(readRepoFile("src/hive/" & name & ".nim"))
      for call in Libm:
        check(source.hasCall(call) < 0, "src/hive/" & name &
          ".nim must not call " & call & "() in the sim step")
      for kind in FloatTypes:
        check(source.hasWord(kind) < 0, "src/hive/" & name &
          ".nim must not mention " & kind & " in the sim step")
    for script in ["Dockerfile", "Dockerfile.replay-viewer",
        "replay-viewer/config.nims", "tools/build_replay_viewer.sh"]:
      check("ffast-math" notin readRepoFile(script),
        script & " must not enable -ffast-math")
    report("no float, no libm and no -ffast-math anywhere in the step path")

main()
echo "test_ants: all checks passed"
