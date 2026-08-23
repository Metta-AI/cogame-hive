## The two scripted baselines. Both emit the identical doctrine JSON on the
## same 10 s cadence as an LLM seat, so their output is legal by construction
## and directly comparable; both are pure functions of the seat's view plus a
## two-field memory, which is what makes the bounded-orders test meaningful.
##
## `marcher` is the certification player, the default, and the stronger of the
## two. `driftling` is deliberately weaker and different in shape so the
## ladder has a spread.

import std/[json, strutils]
import types, doctrine

type
  ScriptKind* = enum
    skNone = "none"
    skMarcher = "marcher"
    skDriftling = "driftling"

  BaselineMemory* = object
    zeroStreak*: int
    recalledLast*: bool

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values, bullwhip's shape: "1"/"true"/"yes"/"marcher"
  ## play the marcher, "driftling" the driftling, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "marcher": skMarcher
  of "driftling", "drift": skDriftling
  else: skNone

proc blockDistance*(ax, ay, bx, by: int): int {.inline.} =
  chebyshev(ax, ay, bx, by)

proc marcherOpening(): Doctrine =
  Doctrine(scouts: 55, trailGain: 25, poach: 10, spread: 55, layFood: 70,
    layHome: 55, recall: false, hasFocus: false, focusWeight: 0,
    note: "marcher: opening", say: "")

proc marcherPump(bx, by: int): Doctrine =
  Doctrine(scouts: 15, trailGain: 78, poach: 12, spread: 32, layFood: 88,
    layHome: 52, recall: false, hasFocus: true, focusBx: bx, focusBy: by,
    focusWeight: 70, note: "marcher: pump", say: "")

proc marcherProbe(bx, by: int): Doctrine =
  Doctrine(scouts: 60, trailGain: 25, poach: 25, spread: 65, layFood: 55,
    layHome: 60, recall: false, hasFocus: true, focusBx: bx, focusBy: by,
    focusWeight: 40, note: "marcher: probe", say: "")

proc driftlingDoctrine*(): Doctrine =
  Doctrine(scouts: 70, trailGain: 25, poach: 45, spread: 70, layFood: 40,
    layHome: 60, recall: false, hasFocus: false, focusWeight: 0,
    note: "driftling: drift", say: "")

proc towardCentre(bx, by: int): tuple[bx, by: int] =
  let cx = BlockCols div 2
  let cy = BlockRows div 2
  var nx = bx
  var ny = by
  if bx < cx: inc nx elif bx > cx: dec nx
  if by < cy: inc ny elif by > cy: dec ny
  (bx: min(BlockCols - 1, max(0, nx)), by: min(BlockRows - 1, max(0, ny)))

proc scriptedDoctrine*(
  view: JsonNode,
  kind: ScriptKind,
  turn: int,
  memory: var BaselineMemory
): Doctrine =
  ## One doctrine for one seat, from that seat's view only.
  if kind == skDriftling:
    memory.recalledLast = false
    memory.zeroStreak = 0
    return driftlingDoctrine()

  let you = view{"you"}
  let deliveredLastTurn = you{"delivered_last_turn"}.getInt(0)
  let hadFocus =
    not you{"last_doctrine"}.isNil and
    you{"last_doctrine"}.kind == JObject and
    not you{"last_doctrine"}{"focus"}.isNil and
    you{"last_doctrine"}{"focus"}.kind != JNull

  if turn > 0:
    if deliveredLastTurn == 0: memory.zeroStreak.inc
    else: memory.zeroStreak = 0

  ## The reset: a dead road is abandoned for exactly one turn and never two
  ## turns running.
  if memory.zeroStreak >= 2 and hadFocus and not memory.recalledLast:
    memory.recalledLast = true
    memory.zeroStreak = 0
    result = marcherOpening()
    result.recall = true
    result.hasFocus = false
    result.focusWeight = 0
    result.note = "marcher: recall"
    return
  memory.recalledLast = false

  if turn < 3:
    return marcherOpening()

  let nestBlock = you{"nest_block"}
  let nbx = if nestBlock.isNil or nestBlock.kind != JArray: 0
            else: nestBlock[0].getInt(0)
  let nby = if nestBlock.isNil or nestBlock.kind != JArray: 0
            else: nestBlock[1].getInt(0)

  var bestScore = low(int)
  var bestBx = -1
  var bestBy = -1
  let sources = view{"sources"}
  if not sources.isNil and sources.kind == JArray:
    for entry in sources:
      let seen = entry{"amount_seen"}.getInt(0)
      if seen <= 0:
        continue
      let blockNode = entry{"block"}
      if blockNode.isNil or blockNode.kind != JArray or blockNode.len != 2:
        continue
      let bx = blockNode[0].getInt(0)
      let by = blockNode[1].getInt(0)
      let score = seen - 2 * blockDistance(nbx, nby, bx, by)
      if score > bestScore:
        bestScore = score
        bestBx = bx
        bestBy = by

  if bestBx >= 0:
    marcherPump(min(BlockCols - 1, max(0, bestBx)),
      min(BlockRows - 1, max(0, bestBy)))
  else:
    let target = towardCentre(nbx, nby)
    marcherProbe(target.bx, target.by)

proc scriptedResolved*(
  view: JsonNode,
  kind: ScriptKind,
  turn: int,
  memory: var BaselineMemory,
  source = dsScripted
): ResolvedDoctrine =
  ResolvedDoctrine(
    doctrine: scriptedDoctrine(view, kind, turn, memory),
    source: source,
    latencyMs: 0
  )
