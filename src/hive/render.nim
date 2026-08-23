## The per-frame viewer packet.
##
## Paintbot's split, kept: the wasm module re-derives the world and emits one
## compact binary packet per frame; the page decodes it and composites the
## painted art (floor, rock, nests, caches, ants) plus the additive pheromone
## glow onto the board canvas. The DOM chrome draws the scorebug, the nest
## counters, the doctrine chips, the feed, the transport and the warnings.
##
## Layout, little-endian throughout (`replay-viewer/static_replay.js` decodes
## it in exactly this order):
##
##   0   4  magic "HVP1"
##   4   4  tick (u32)
##   8   4  turn (u32)
##   12  2  cols (u16)
##   14  2  rows (u16)
##   16  2  antCount (u16)
##   18  2  sourceCount (u16)
##   20  4  digest (u32)
##   24 16  delivered[4] (u32, SEAT order)
##   40  8  carrying[4] (u16, SEAT order)
##   48  4  seatNest[4] (u8)
##   52  .. ants: antCount x (cx u8, cy u8, state u8, colony u8)
##      .. sources: sourceCount x (id u16, cx u8, cy u8, amount u16,
##                                 spawnAmount u16)
##      .. pheromone: 4 colonies x 2 planes x cols*rows bytes, each
##         `value * 255 div pheromoneMax`

import types, pheromones, sim

const PacketMagic* = "HVP1"

proc putU8(buffer: var seq[uint8], value: int) {.inline.} =
  buffer.add(uint8(value and 0xff))

proc putU16(buffer: var seq[uint8], value: int) {.inline.} =
  buffer.add(uint8(value and 0xff))
  buffer.add(uint8((value shr 8) and 0xff))

proc putU32(buffer: var seq[uint8], value: uint32) {.inline.} =
  buffer.add(uint8(value and 0xff'u32))
  buffer.add(uint8((value shr 8) and 0xff'u32))
  buffer.add(uint8((value shr 16) and 0xff'u32))
  buffer.add(uint8((value shr 24) and 0xff'u32))

proc buildViewerPacket*(match: Sim): seq[uint8] =
  var live = 0
  for item in match.sources.items:
    if item.alive:
      inc live
  let antCount = match.antsTotal()
  result = newSeqOfCap[uint8](
    52 + antCount * 4 + live * 8 + Colonies * 2 * match.meadow.cols *
      match.meadow.rows)
  for ch in PacketMagic:
    result.add(uint8(ord(ch)))
  result.putU32(uint32(match.tick))
  result.putU32(uint32(match.turn))
  result.putU16(match.meadow.cols)
  result.putU16(match.meadow.rows)
  result.putU16(antCount)
  result.putU16(live)
  result.putU32(match.lastDigest)
  for seat in 0 ..< Colonies:
    result.putU32(uint32(match.delivered[match.seatNest[seat]]))
  for seat in 0 ..< Colonies:
    let colony = match.seatNest[seat]
    var carrying = 0
    for index in 0 ..< match.config.antsPerColony:
      if match.antState[colony * match.config.antsPerColony + index].carrying:
        inc carrying
    result.putU16(carrying)
  for seat in 0 ..< Colonies:
    result.putU8(match.seatNest[seat])
  for g in 0 ..< antCount:
    result.putU8(int(match.antState[g].cx))
    result.putU8(int(match.antState[g].cy))
    result.add(match.antStateCode(g))
    result.putU8(g div match.config.antsPerColony)
  for item in match.sources.items:
    if not item.alive:
      continue
    result.putU16(int(item.id))
    result.putU8(int(item.cx))
    result.putU8(int(item.cy))
    result.putU16(int(item.amount))
    result.putU16(int(item.spawnAmount))
  let cap = max(1, match.config.pheromoneMax)
  for colony in 0 ..< Colonies:
    for plane in 0 .. 1:
      for value in match.planes.cells[colony][plane]:
        result.add(uint8((int(value) * 255) div cap))
