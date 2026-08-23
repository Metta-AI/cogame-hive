## The eight pheromone planes: one FOOD and one HOME plane per colony, a
## `uint16` per cell, deposit / saturate / decay-in-place / block downsample.
##
## New in hive (paintbot has no field of this shape). Everything here is
## integer: `p <- (p * pheromoneDecayNum) shr 8`, no float, no libm, so the
## native and emscripten builds agree digest-for-digest.

import types

type
  Planes* = object
    ## `[colony][plane]` where plane 0 = FOOD, plane 1 = HOME.
    cells*: array[Colonies, array[2, seq[uint16]]]
    cols*: int
    rows*: int

const
  PlaneFood* = 0
  PlaneHome* = 1

proc initPlanes*(cols, rows: int): Planes =
  result.cols = cols
  result.rows = rows
  for colony in 0 ..< Colonies:
    for plane in 0 .. 1:
      result.cells[colony][plane] = newSeq[uint16](cols * rows)

proc get*(planes: Planes, colony, plane, cx, cy: int): int {.inline.} =
  int(planes.cells[colony][plane][cy * planes.cols + cx])

proc deposit*(planes: var Planes, colony, plane, cx, cy, amount, cap: int) =
  ## Adds to a cell, saturating at `cap`. Never wraps the uint16.
  let index = cy * planes.cols + cx
  var value = int(planes.cells[colony][plane][index]) + amount
  if value > cap:
    value = cap
  if value < 0:
    value = 0
  planes.cells[colony][plane][index] = uint16(value)

proc decay*(planes: var Planes, decayNum, floorValue: int) =
  ## `p <- (p * decayNum) shr 8`, then anything under `floorValue` is zeroed.
  ## Zero cells are skipped, which is most of the field for most of a match.
  for colony in 0 ..< Colonies:
    for plane in 0 .. 1:
      for index in 0 ..< planes.cells[colony][plane].len:
        let value = int(planes.cells[colony][plane][index])
        if value == 0:
          continue
        var next = (value * decayNum) shr 8
        if next < floorValue:
          next = 0
        planes.cells[colony][plane][index] = uint16(next)

proc blockMean*(planes: Planes, colony, plane, bx, by: int): int =
  ## Mean plane value over one 8 x 8 observation block.
  var total = 0
  for dy in 0 ..< BlockCells:
    let row = (by * BlockCells + dy) * planes.cols + bx * BlockCells
    for dx in 0 ..< BlockCells:
      total += int(planes.cells[colony][plane][row + dx])
  total div (BlockCells * BlockCells)

proc blockDigit*(value, cap: int): char {.inline.} =
  ## `min(9, (mean * 10) div (cap + 1))` as an ASCII digit.
  var digit = (value * 10) div (cap + 1)
  if digit > 9: digit = 9
  if digit < 0: digit = 0
  char(ord('0') + digit)

proc blockRows*(planes: Planes, colony, plane, cap: int): seq[string] =
  ## The 11 x 20 digit grid one colony sees of one of its own planes.
  result = @[]
  for by in 0 ..< BlockRows:
    var row = newString(BlockCols)
    for bx in 0 ..< BlockCols:
      row[bx] = blockDigit(planes.blockMean(colony, plane, bx, by), cap)
    result.add(row)

proc rivalFoodMax*(planes: Planes, colony, cx, cy: int): int {.inline.} =
  ## The largest FOOD value among the other three colonies at one cell - an
  ## ant literally smells a rival's road under its feet.
  let index = cy * planes.cols + cx
  var best = 0
  for other in 0 ..< Colonies:
    if other == colony:
      continue
    let value = int(planes.cells[other][PlaneFood][index])
    if value > best:
      best = value
  best

proc rivalBlockMax*(planes: Planes, colony, bx, by: int): int =
  ## The largest of the other three colonies' block-mean FOOD readings.
  var best = 0
  for other in 0 ..< Colonies:
    if other == colony:
      continue
    let value = planes.blockMean(other, PlaneFood, bx, by)
    if value > best:
      best = value
  best

proc peakFood*(planes: Planes, colony: int): int =
  var best = 0
  for value in planes.cells[colony][PlaneFood]:
    if int(value) > best:
      best = int(value)
  best
