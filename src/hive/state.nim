## Digest, event buffer and logging - paintbot's `src/ctf/sim_state.nim`
## widened. Paintbot's `gameHash` covers the state the replay does not carry;
## hive's `hiveStateDigest` covers the WHOLE state including all eight
## pheromone planes, because the viewer re-derives the field rather than
## receiving it and the digest is the proof it got the same match.

import std/json
import types

type
  Fnv* = object
    ## FNV-1a over raw little-endian bytes, u32.
    value*: uint32

  EventBuffer* = object
    items*: seq[JsonNode]
    logging*: bool

const
  FnvOffset = 2166136261'u32
  FnvPrime = 16777619'u32

proc initFnv*(): Fnv =
  Fnv(value: FnvOffset)

proc feedByte*(hash: var Fnv, value: uint8) {.inline.} =
  hash.value = (hash.value xor uint32(value)) * FnvPrime

proc feedU16*(hash: var Fnv, value: uint16) {.inline.} =
  hash.feedByte(uint8(value and 0xff'u16))
  hash.feedByte(uint8((value shr 8) and 0xff'u16))

proc feedU32*(hash: var Fnv, value: uint32) {.inline.} =
  hash.feedByte(uint8(value and 0xff'u32))
  hash.feedByte(uint8((value shr 8) and 0xff'u32))
  hash.feedByte(uint8((value shr 16) and 0xff'u32))
  hash.feedByte(uint8((value shr 24) and 0xff'u32))

proc feedU64*(hash: var Fnv, value: uint64) {.inline.} =
  hash.feedU32(uint32(value and 0xffffffff'u64))
  hash.feedU32(uint32((value shr 32) and 0xffffffff'u64))

proc feedInt*(hash: var Fnv, value: int) {.inline.} =
  hash.feedU32(cast[uint32](int32(value)))

proc initEventBuffer*(logging: bool): EventBuffer =
  EventBuffer(items: @[], logging: logging)

proc add*(buffer: var EventBuffer, event: JsonNode) =
  buffer.items.add(event)
  if buffer.logging:
    echo "hive event: ", $event

proc toJson*(buffer: EventBuffer): JsonNode =
  result = newJArray()
  for item in buffer.items:
    result.add(item)

proc countOf*(buffer: EventBuffer, kind: string): int =
  for item in buffer.items:
    if item{"type"}.getStr() == kind:
      inc result

proc logLine*(message: string) =
  echo "hive: ", message

proc quitError*(message: string) {.noreturn.} =
  ## One clean line, no traceback: `/bin/hive` exits 2 on a broken contract.
  stderr.writeLine("hive: " & message)
  quit(2)
