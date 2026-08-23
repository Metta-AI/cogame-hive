## Hive core types and constants.
##
## Forked from paintbot's `src/ctf/sim_types.nim`: the tick rate, the
## playback-speed ladder, the map-global install pattern and the
## `GameVersion` rules gate all survive. Paintbot's continuous-motion
## constant family (MotionScale / Accel / FrictionNum / MaxSpeed /
## StopThreshold / PlayerHalf / PlayerBouncePct / MovementSlideMaxScan) is
## DROPPED on purpose: a pheromone field is a lattice, ants step cell to
## cell, and an integer lattice is what makes the native and emscripten
## builds agree bit-for-bit with no float anywhere in the step.
##
## Rules changelog (prepend-only, paintbot's convention):
##   GV2 (recall walks home): a recalled ant runs the CARRYING kernel in
##     step 8 regardless of its carrying flag, so it rides the home trail
##     home instead of being repelled by it. Neither committed fixture
##     carries recall: true, so the recorded digests are unchanged.
##   GV1 (forage): four colonies, two pheromone planes, doctrine turns.



const
  GameVersion* = "2"
    ## Rules gate. Bump on any change to the integer step.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  FieldCols* = 160
  FieldRows* = 88
  CellPx* = 8
  MapWidth* = FieldCols * CellPx    ## 1280
  MapHeight* = FieldRows * CellPx   ## 704

  BlockCells* = 8
  BlockCols* = FieldCols div BlockCells   ## 20
  BlockRows* = FieldRows div BlockCells   ## 11
  BlockCount* = BlockCols * BlockRows     ## 220

  Colonies* = 4
  CellCount* = FieldCols * FieldRows

  ## Kernel coefficients that never come from the doctrine.
  AlphaScent* = 900
  BetaNest* = 1200
  BetaFwd* = 260
  CarryNoise* = 32

  ## Recorded-string caps, in RUNES (never bytes).
  MaxNoteRunes* = 140
  MaxSayRunes* = 32
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxPromptRunes* = 4000

  ## Ant state codes as written into the replay's `ants_b64`.
  AntStateForager* = 0'u8
  AntStateScout* = 1'u8
  AntStateCarrying* = 2'u8
  AntStateHeld* = 3'u8

  ## Eight headings, 0 = E, counter-clockwise in 45 degree steps.
  DirX*: array[8, int] = [1, 1, 0, -1, -1, -1, 0, 1]
  DirY*: array[8, int] = [0, -1, -1, -1, 0, 1, 1, 1]

  ## Pickup scan order around the ant: N, NE, E, SE, S, SW, W, NW.
  ScanX*: array[8, int] = [0, 1, 1, 1, 0, -1, -1, -1]
  ScanY*: array[8, int] = [-1, -1, 0, 1, 1, 1, 0, -1]

type
  HiveError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    antsPerColony*: int
    episodeTicks*: int
    turnTicks*: int
    antStepTicks*: int
    cellPx*: int
    pheromoneMax*: int
    pheromoneFloor*: int
    pheromoneDecayNum*: int
    decayPeriodTicks*: int
    nestSenseCells*: int
    maxOrbits*: int
    sourceSpawnPeriod*: int
    sourceAmount*: int
    sourceLifeTicks*: int
    minNestClearance*: int
    bonanzaTicks*: seq[int]
    bonanzaAmount*: int
    bonanzaLifeTicks*: int
    raidRadius*: int
    trailWarThreshold*: int
    turnBudgetSeconds*: float
    wallClockBudgetSeconds*: float
    playerConnectTimeoutSeconds*: float
    episodeTimeoutSeconds*: int
    fieldPath*: string
    showPlayerLabels*: bool
    gameOverTicks*: int

  Doctrine* = object
    ## The batched-over-bodies vector one colony plays for one turn.
    scouts*: int
    trailGain*: int
    poach*: int
    spread*: int
    layFood*: int
    layHome*: int
    recall*: bool
    hasFocus*: bool
    focusBx*: int
    focusBy*: int
    focusWeight*: int
    note*: string
    say*: string

  DoctrineSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  ResolvedDoctrine* = object
    doctrine*: Doctrine
    source*: DoctrineSource
    latencyMs*: int

  Coefficients* = object
    ## The integer kernel weights a doctrine compiles to.
    alphaFood*: int
    alphaRival*: int
    alphaHome*: int
    alphaFwd*: int
    alphaNoise*: int
    betaHome*: int
    layFood*: int
    layHome*: int
    scoutCount*: int

  Ant* = object
    cx*: int32
    cy*: int32
    heading*: int32
    carrying*: bool
    carriedFrom*: int32
    held*: bool          ## parked in the nest pad by an active recall
    scout*: bool         ## recomputed at each turn install

  Source* = object
    id*: int32
    cx*: int32
    cy*: int32
    amount*: int32
    spawnAmount*: int32
    spawnTick*: int32
    lifeTicks*: int32
    alive*: bool
    bonanza*: bool

  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erFault = "fault"

  EndRule* = enum
    euFullTime = "full_time"
    euWallClock = "wall_clock"
    euSimFault = "sim_fault"
    euHostError = "host_error"

proc blockOf*(cx, cy: int): int {.inline.} =
  (cy div BlockCells) * BlockCols + (cx div BlockCells)

proc blockX*(index: int): int {.inline.} = index mod BlockCols
proc blockY*(index: int): int {.inline.} = index div BlockCols

proc chebyshev*(ax, ay, bx, by: int): int {.inline.} =
  let dx = if ax > bx: ax - bx else: bx - ax
  let dy = if ay > by: ay - by else: by - ay
  if dx > dy: dx else: dy

# ---- PCG32: the one random stream in the episode ---------------------------
#
# Integer arithmetic only. Advanced in a fixed order (seat permutation once at
# init, then per tick: sources, then ants in ant order), so the draw sequence
# is a function of the seed and the doctrines alone.

type
  Pcg* = object
    state*: uint64
    inc*: uint64

proc initPcg*(seed: int): Pcg =
  result.state = 0'u64
  result.inc = 0xda3e39cb94b95bdb'u64
  result.state = result.state * 6364136223846793005'u64 + result.inc
  result.state = result.state + cast[uint64](int64(seed))
  result.state = result.state * 6364136223846793005'u64 + result.inc

proc nextU32*(rng: var Pcg): uint32 =
  let old = rng.state
  rng.state = old * 6364136223846793005'u64 + rng.inc
  let xorshifted = uint32(((old shr 18) xor old) shr 27)
  let rot = uint32(old shr 59)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc rnd*(rng: var Pcg, bound: int): int =
  ## Uniform in `0 ..< bound` (0 when bound <= 1). Modulo bias is accepted
  ## deliberately: the bounds here are tiny and reproducibility beats
  ## perfection.
  if bound <= 1:
    return 0
  int(rng.nextU32() mod uint32(bound))
