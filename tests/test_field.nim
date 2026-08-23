## The one authored field: it loads, it is exactly mirror-symmetric on both
## axes, every nest pad and every bonanza cell is free floor, the free floor
## is a single 4-connected component, the nest centres are the mirror orbit of
## (16, 12), and block indices map to cells as documented.

import std/json
import support/helpers
import hive/field

proc main() =
  let meadow = testField()

  block loads:
    checkEqual(meadow.name, "meadow", "field name")
    checkEqual(meadow.cols, FieldCols, "cols")
    checkEqual(meadow.rows, FieldRows, "rows")
    checkEqual(meadow.cellPx, CellPx, "cell_px")
    checkEqual(meadow.nestRadius, 2, "nest radius")
    check(meadow.spec.hasKey("rock") and meadow.spec["rock"].len >= 4,
      "the spec authors rock shapes")
    report("data/meadow.fieldspec.json loads and bakes")

  block mirrors:
    for cy in 0 ..< meadow.rows:
      for cx in 0 ..< meadow.cols:
        check(meadow.isRock(cx, cy) == meadow.isRock(meadow.cols - 1 - cx, cy),
          "rock mask is invariant under cx -> 159 - cx at (" & $cx & "," & $cy & ")")
        check(meadow.isRock(cx, cy) == meadow.isRock(cx, meadow.rows - 1 - cy),
          "rock mask is invariant under cy -> 87 - cy at (" & $cx & "," & $cy & ")")
    report("the baked mask is invariant under both mirrors")

  block padsAreFloor:
    for nest in 0 ..< Colonies:
      for dy in -meadow.nestRadius .. meadow.nestRadius:
        for dx in -meadow.nestRadius .. meadow.nestRadius:
          check(meadow.isFree(meadow.nests[nest].cx + dx,
              meadow.nests[nest].cy + dy),
            "nest " & $nest & " pad cell is free floor")
    for cell in meadow.bonanzaCells:
      check(meadow.isFree(cell.cx, cell.cy), "bonanza cell is free floor")
    checkEqual(meadow.bonanzaCells.len, 4, "four bonanza cells")
    report("every nest pad and every bonanza cell is free floor")

  block connectivity:
    checkEqual(meadow.freeFloorComponents(), 1,
      "the free floor is a single 4-connected component")
    var rock = 0
    for value in meadow.rock:
      if value: inc rock
    check(rock * 100 div meadow.rock.len >= 5,
      "the meadow carries enough rock to make corridors")
    check(rock * 100 div meadow.rock.len <= 30,
      "the meadow is not so rocky that it fragments the floor")
    report("the free floor is one component with 5-30% rock")

  block nestOrbit:
    let base = (cx: 16, cy: 12)
    var wanted = @[
      (cx: base.cx, cy: base.cy),
      (cx: FieldCols - 1 - base.cx, cy: base.cy),
      (cx: base.cx, cy: FieldRows - 1 - base.cy),
      (cx: FieldCols - 1 - base.cx, cy: FieldRows - 1 - base.cy)
    ]
    for nest in 0 ..< Colonies:
      let here = (cx: meadow.nests[nest].cx, cy: meadow.nests[nest].cy)
      var found = -1
      for index, cell in wanted:
        if cell == here: found = index
      check(found >= 0, "nest " & $nest & " is in the mirror orbit of (16,12)")
      wanted.delete(found)
    checkEqual(wanted.len, 0, "the four nests are exactly the orbit")
    checkEqual(meadow.nests[0].alias, "Amber", "N0 is Amber")
    checkEqual(meadow.nests[3].alias, "Magenta", "N3 is Magenta")
    report("the four nest centres are the mirror orbit of (16, 12)")

  block blockMapping:
    checkEqual(blockOf(0, 0), 0, "cell (0,0) is block 0")
    checkEqual(blockOf(7, 7), 0, "cell (7,7) is still block 0")
    checkEqual(blockOf(8, 0), 1, "cell (8,0) is block 1")
    checkEqual(blockOf(FieldCols - 1, FieldRows - 1), BlockCount - 1,
      "the last cell is the last block")
    checkEqual(blockX(blockOf(76, 43)), 9, "block x of cell (76,43)")
    checkEqual(blockY(blockOf(76, 43)), 5, "block y of cell (76,43)")
    let rows = meadow.rockBlockRows()
    checkEqual(rows.len, BlockRows, "eleven block rows")
    for row in rows:
      checkEqual(row.len, BlockCols, "twenty columns a row")
    report("block indices map to cells as documented")

main()
echo "test_field: all checks passed"
