## Sim unit tests on the pheromone field: saturation, the decay rule and its
## cadence, the stated half-life, the floor, the block downsample, and the
## independence of the eight planes.

import std/strutils
import support/helpers
import hive/pheromones

proc main() =
  let cap = 4000

  block saturation:
    var planes = initPlanes(FieldCols, FieldRows)
    for _ in 0 .. 40:
      planes.deposit(0, PlaneFood, 10, 10, 200, cap)
    checkEqual(planes.get(0, PlaneFood, 10, 10), cap,
      "a deposit saturates at exactly pheromoneMax")
    planes.deposit(0, PlaneFood, 10, 10, 60000, cap)
    checkEqual(planes.get(0, PlaneFood, 10, 10), cap,
      "an enormous deposit never wraps the uint16")
    report("deposit saturates at pheromoneMax and never wraps")

  block decayRule:
    var planes = initPlanes(FieldCols, FieldRows)
    planes.deposit(1, PlaneHome, 3, 4, 1000, cap)
    planes.decay(248, 4)
    checkEqual(planes.get(1, PlaneHome, 3, 4), (1000 * 248) shr 8,
      "decay applies (p*248) shr 8")
    report("decay applies the integer rule exactly")

  block halfLife:
    ## The stated half-life is about 175 ticks: decay fires every 8 ticks, so
    ## 175 ticks is 21 or 22 applications.
    var planes = initPlanes(FieldCols, FieldRows)
    planes.deposit(0, PlaneFood, 5, 5, cap, cap)
    var tick = 0
    var crossed = -1
    while tick < 4800:
      tick += 8
      planes.decay(248, 4)
      if crossed < 0 and planes.get(0, PlaneFood, 5, 5) < cap div 2:
        crossed = tick
    check(crossed >= 168 and crossed <= 184,
      "an unreinforced 4000 cell drops below 2000 at 175 +/- 8 ticks, got " &
      $crossed)
    checkEqual(planes.get(0, PlaneFood, 5, 5), 0,
      "the cell is exactly 0 once it drops under pheromoneFloor")
    report("half-life is ~175 ticks and the floor zeroes the cell")

  block zeroSkipped:
    var planes = initPlanes(FieldCols, FieldRows)
    for _ in 0 .. 200:
      planes.decay(248, 4)
    checkEqual(planes.get(2, PlaneFood, 100, 40), 0,
      "a zero cell is skipped and stays zero")
    report("zero cells stay zero")

  block downsample:
    ## A hand-built plane: block (1, 0) carries 2048 in every cell, so its
    ## digit is min(9, 2048*10 div 4001) = 5; block (0, 0) is empty.
    var planes = initPlanes(FieldCols, FieldRows)
    for dy in 0 ..< BlockCells:
      for dx in 0 ..< BlockCells:
        planes.deposit(0, PlaneFood, BlockCells + dx, dy, 2048, cap)
    checkEqual(planes.blockMean(0, PlaneFood, 1, 0), 2048, "block mean")
    let rows = planes.blockRows(0, PlaneFood, cap)
    checkEqual(rows.len, BlockRows, "one string per block row")
    checkEqual(rows[0].len, BlockCols, "one char per block column")
    checkEqual(rows[0][0], '0', "an empty block reads 0")
    checkEqual(rows[0][1], '5', "a 2048 block reads 5")
    checkEqual(rows[0], "05" & repeat('0', BlockCols - 2),
      "the whole digit row matches the hand-computed string")
    report("the 8x8 block downsample matches a hand-computed digit string")

  block independence:
    var planes = initPlanes(FieldCols, FieldRows)
    planes.deposit(0, PlaneFood, 20, 20, 3000, cap)
    for colony in 1 ..< Colonies:
      checkEqual(planes.get(colony, PlaneFood, 20, 20), 0,
        "writing Amber's F never moves colony " & $colony & "'s F")
    checkEqual(planes.get(0, PlaneHome, 20, 20), 0,
      "writing F never moves the same colony's H")
    checkEqual(planes.rivalFoodMax(1, 20, 20), 3000,
      "a rival reads the max of the other three colonies' F")
    checkEqual(planes.rivalFoodMax(0, 20, 20), 0,
      "a colony never smells its own trail as a rival trail")
    report("the eight planes are fully independent")

main()
echo "test_pheromones: all checks passed"
