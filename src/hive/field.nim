## The meadow: an authored field spec, stamped and mirrored into a rock mask.
##
## Forked from paintbot's `src/ctf/arena.nim`: the `mapSpec`-style loader, the
## rect/disc/polygon stamping, the mask bake, the integer even-odd
## `pointInPolygon` with its STRICT-STRADDLE convention, and the process-global
## install. Paintbot's procedural generator, validators, `mapDiagnostics`,
## `map_pool.nim`, `mapgen_styles.nim` and the whole
## mapSize/mapSymmetry/mapEndzone knob family are DROPPED: hive ships one
## authored field, because four-way mirror fairness plus a hand-tuned rock
## distribution is not something a seeded draw gives you.
##
## Only the shapes an author writes matter; the loader ORs in all four mirror
## images (`cx -> cols-1-cx`, `cy -> rows-1-cy`), so the symmetry cannot drift.

import std/[json, os]
import types

type
  ShapeKind* = enum
    skRect = "rect"
    skDisc = "disc"
    skPolygon = "polygon"

  RockShape* = object
    kind*: ShapeKind
    cx*, cy*, w*, h*, r*: int
    points*: seq[tuple[x, y: int]]

  Nest* = object
    id*: string
    alias*: string
    colour*: string
    cx*: int
    cy*: int

  Field* = object
    name*: string
    cols*: int
    rows*: int
    cellPx*: int
    nestRadius*: int
    rock*: seq[bool]
    nests*: array[Colonies, Nest]
    spawnQuadrant*: array[4, int]  ## cxLo, cyLo, cxHi, cyHi (inclusive)
    bonanzaCells*: seq[tuple[cx, cy: int]]
    spec*: JsonNode                ## the authored spec, verbatim, pre-mirroring

proc pointInPolygon*(x, y: int, pts: seq[tuple[x, y: int]]): bool =
  ## Integer even-odd point-in-polygon, kept from paintbot verbatim in shape:
  ## crossings are counted STRICTLY LEFT and STRICTLY RIGHT of the sample and
  ## the point is inside when either count is odd, which is exactly
  ## reflection-symmetric under both mirrors. An edge is counted only on a
  ## STRICT straddle (`ylo < y < yhi`), so a vertex touch is skipped
  ## identically on both sides. int64 throughout: cross products of field-scale
  ## coordinates overflow int32 on wasm.
  if pts.len < 3:
    return false
  var
    minx = pts[0].x
    maxx = pts[0].x
    miny = pts[0].y
    maxy = pts[0].y
  for p in pts:
    minx = min(minx, p.x); maxx = max(maxx, p.x)
    miny = min(miny, p.y); maxy = max(maxy, p.y)
  ## Bounding-box rejection first: the "odd on either side" rule is only
  ## meaningful inside the ring's own box.
  if x < minx or x > maxx or y < miny or y > maxy:
    return false
  var
    leftCross = 0
    rightCross = 0
    j = pts.len - 1
  for i in 0 ..< pts.len:
    let
      xi = pts[i].x
      yi = pts[i].y
      xj = pts[j].x
      yj = pts[j].y
      ylo = min(yi, yj)
      yhi = max(yi, yj)
    if y > ylo and y < yhi:
      let
        dyv = int64(yj - yi)
        lhs = int64(x - xi) * dyv
        rhs = int64(xj - xi) * int64(y - yi)
      if (if dyv > 0: lhs < rhs else: lhs > rhs):
        inc leftCross
      elif (if dyv > 0: lhs > rhs else: lhs < rhs):
        inc rightCross
    j = i
  (leftCross and 1) == 1 or (rightCross and 1) == 1

proc inShape*(x, y: int, shape: RockShape): bool =
  ## `rect` is (cx, cy) top-left corner plus w x h cells; `disc` is a filled
  ## circle of radius r about (cx, cy); `polygon` is the even-odd ring above.
  case shape.kind
  of skRect:
    x >= shape.cx and x < shape.cx + shape.w and
      y >= shape.cy and y < shape.cy + shape.h
  of skDisc:
    let
      dx = x - shape.cx
      dy = y - shape.cy
    dx * dx + dy * dy <= shape.r * shape.r
  of skPolygon:
    pointInPolygon(x, y, shape.points)

proc parseShape(node: JsonNode): RockShape =
  let kind = node{"kind"}.getStr("rect")
  case kind
  of "rect":
    result = RockShape(kind: skRect, cx: node["cx"].getInt(),
      cy: node["cy"].getInt(), w: node["w"].getInt(), h: node["h"].getInt())
  of "disc":
    result = RockShape(kind: skDisc, cx: node["cx"].getInt(),
      cy: node["cy"].getInt(), r: node["r"].getInt())
  of "polygon":
    result = RockShape(kind: skPolygon)
    for point in node["points"]:
      result.points.add((x: point[0].getInt(), y: point[1].getInt()))
  else:
    raise newException(HiveError, "unknown rock shape kind: " & kind)

proc index*(field: Field, cx, cy: int): int {.inline.} =
  cy * field.cols + cx

proc onField*(field: Field, cx, cy: int): bool {.inline.} =
  cx >= 0 and cx < field.cols and cy >= 0 and cy < field.rows

proc isRock*(field: Field, cx, cy: int): bool {.inline.} =
  if not field.onField(cx, cy): true
  else: field.rock[cy * field.cols + cx]

proc isFree*(field: Field, cx, cy: int): bool {.inline.} =
  field.onField(cx, cy) and not field.rock[cy * field.cols + cx]

proc inNestPad*(field: Field, nest: int, cx, cy: int): bool {.inline.} =
  chebyshev(cx, cy, field.nests[nest].cx, field.nests[nest].cy) <=
    field.nestRadius

proc parseFieldSpec*(spec: JsonNode): Field =
  ## Bakes the mask. All authored shapes are stamped, then the mask is ORed
  ## with its three mirror images so the meadow is invariant under both axes.
  result.spec = spec
  result.name = spec{"name"}.getStr("meadow")
  result.cols = spec{"cols"}.getInt(FieldCols)
  result.rows = spec{"rows"}.getInt(FieldRows)
  result.cellPx = spec{"cell_px"}.getInt(CellPx)
  result.nestRadius = spec{"nest_radius"}.getInt(2)
  if result.cols != FieldCols or result.rows != FieldRows:
    raise newException(HiveError,
      "field must be " & $FieldCols & "x" & $FieldRows)

  var shapes: seq[RockShape]
  if spec.hasKey("rock"):
    for node in spec["rock"]:
      shapes.add(parseShape(node))

  var base = newSeq[bool](result.cols * result.rows)
  for cy in 0 ..< result.rows:
    for cx in 0 ..< result.cols:
      for shape in shapes:
        if inShape(cx, cy, shape):
          base[cy * result.cols + cx] = true
          break

  result.rock = newSeq[bool](result.cols * result.rows)
  for cy in 0 ..< result.rows:
    let my = result.rows - 1 - cy
    for cx in 0 ..< result.cols:
      let mx = result.cols - 1 - cx
      result.rock[cy * result.cols + cx] =
        base[cy * result.cols + cx] or base[cy * result.cols + mx] or
        base[my * result.cols + cx] or base[my * result.cols + mx]

  let nests = spec["nests"]
  if nests.len != Colonies:
    raise newException(HiveError, "field must declare " & $Colonies & " nests")
  for i in 0 ..< Colonies:
    result.nests[i] = Nest(
      id: nests[i]{"id"}.getStr("N" & $i),
      alias: nests[i]{"alias"}.getStr(),
      colour: nests[i]{"colour"}.getStr("#ffffff"),
      cx: nests[i]["cell"][0].getInt(),
      cy: nests[i]["cell"][1].getInt()
    )

  let quadrant = spec["spawn_quadrant"]
  for i in 0 .. 3:
    result.spawnQuadrant[i] = quadrant[i].getInt()

  for node in spec["bonanza_cells"]:
    result.bonanzaCells.add((cx: node[0].getInt(), cy: node[1].getInt()))

  ## Nest pads and bonanza cells are floor by construction of the authored
  ## spec; a spec that buries one is rejected here rather than at tick 0.
  for nest in 0 ..< Colonies:
    for dy in -result.nestRadius .. result.nestRadius:
      for dx in -result.nestRadius .. result.nestRadius:
        let cx = result.nests[nest].cx + dx
        let cy = result.nests[nest].cy + dy
        if not result.isFree(cx, cy):
          raise newException(HiveError,
            "nest pad cell (" & $cx & "," & $cy & ") is rock or off-field")
  for cell in result.bonanzaCells:
    if not result.isFree(cell.cx, cell.cy):
      raise newException(HiveError, "bonanza cell is rock")

proc freeFloorComponents*(field: Field): int =
  ## Number of 4-connected components of free floor. The kernel's
  ## "boxed in => turn 90 degrees" rule terminates only while this is 1.
  var seen = newSeq[bool](field.cols * field.rows)
  var components = 0
  var stack: seq[int]
  for start in 0 ..< field.cols * field.rows:
    if field.rock[start] or seen[start]:
      continue
    inc components
    seen[start] = true
    stack.setLen(0)
    stack.add(start)
    while stack.len > 0:
      let current = stack.pop()
      let cx = current mod field.cols
      let cy = current div field.cols
      for k in 0 .. 3:
        let nx = cx + [1, -1, 0, 0][k]
        let ny = cy + [0, 0, 1, -1][k]
        if not field.onField(nx, ny):
          continue
        let next = ny * field.cols + nx
        if field.rock[next] or seen[next]:
          continue
        seen[next] = true
        stack.add(next)
  components

proc fieldSpecPath*(name: string): string =
  ## Resolves `data/<name>.fieldspec.json` next to the binary or the repo root.
  let file = name & ".fieldspec.json"
  let appDir = getAppDir()
  for candidate in [appDir / "data" / file, appDir / ".." / "data" / file,
      "data" / file]:
    if fileExists(candidate):
      return candidate
  "data" / file

## Process-global installed field (paintbot's map-global install pattern):
## the sim, the server and the wasm viewer all read one baked mask.
var installedField: Field
var installedName: string

proc loadField*(name: string): Field =
  ## Loads and bakes `data/<name>.fieldspec.json`.
  let path = fieldSpecPath(name)
  if not fileExists(path):
    raise newException(HiveError, "field spec not found: " & path)
  parseFieldSpec(parseJson(readFile(path)))

proc installField*(field: Field) =
  installedField = field
  installedName = field.name

proc currentField*(): Field =
  installedField

proc ensureField*(name: string): Field =
  ## Loads the named field once per process and returns the installed bake.
  if installedName != name or installedField.rock.len == 0:
    installField(loadField(name))
  installedField

proc rockBlockRows*(field: Field): seq[string] =
  ## One string per block row, `#` where more than half the block's cells are
  ## rock. This is the terrain every seat sees, always - rock is not secret.
  result = @[]
  for by in 0 ..< BlockRows:
    var row = newString(BlockCols)
    for bx in 0 ..< BlockCols:
      var count = 0
      for dy in 0 ..< BlockCells:
        for dx in 0 ..< BlockCells:
          if field.isRock(bx * BlockCells + dx, by * BlockCells + dy):
            inc count
      row[bx] = if count * 2 > BlockCells * BlockCells: '#' else: '.'
    result.add(row)
