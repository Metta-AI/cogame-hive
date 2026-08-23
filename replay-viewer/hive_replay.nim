## The static wasm replay module.
##
## Forked from paintbot's `replay-viewer/ctf_replay.nim`: the same exported
## surface, the same `stampStage` progress-note discipline, the same
## `-s ABORTING_MALLOC=1` link and the same
## `emscripten_exit_with_live_runtime()` epilogue skip. All four exist because
## of bugs paintbot already paid for.
##
## The module re-runs THE SAME integer sim the game server runs, from the
## recorded doctrine stream, so the pheromone field is re-derived rather than
## transported. Every keyframe's digest is compared against the recorded one;
## the first mismatch lights `#mmwarn` and playback continues.

import std/json
import hive/[types, field, render, replay, sim]

var
  runtimeLoaded = false
  player: ReplayPlayer
  packet: seq[uint8]
  rockMask: seq[uint8]
  lastError: string
  pendingSeek = -1
  pendingAdvance = 1

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals. The bundle is therefore linked with
## `-s ABORTING_MALLOC=1` and this fixed buffer, stamped BEFORE each risky
## phase, stays readable from JS after the abort (aborting kills the call
## stack, not the linear memory).
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc hiveLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "hive_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let parsed = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    player = initReplayRuntime(parsed, mismatchQuit = false)
    stampStage("bake field mask")
    rockMask = newSeq[uint8](player.match.meadow.rock.len)
    for index in 0 ..< player.match.meadow.rock.len:
      rockMask[index] = if player.match.meadow.rock[index]: 1'u8 else: 0'u8
    stampStage("build first frame")
    packet = buildViewerPacket(player.match)
    runtimeLoaded = true
    pendingSeek = -1
    pendingAdvance = 0
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    return 0

proc hiveInput(data: ptr uint8, length: cint) {.exportc: "hive_input", cdecl.} =
  ## `{"seek": <tick>}` or `{"advance": <ticks>}`. The command is applied by
  ## the next `hive_frame()`, which builds exactly one packet however many
  ## ticks it advanced.
  if not runtimeLoaded:
    return
  try:
    let node = parseJson(data.bytesFromPointer(int(length)))
    if node.hasKey("seek"):
      pendingSeek = node["seek"].getInt()
      pendingAdvance = 0
    elif node.hasKey("advance"):
      pendingAdvance = max(0, node["advance"].getInt())
      pendingSeek = -1
  except CatchableError as error:
    lastError = "input: " & error.msg

proc hiveFrame(): cint {.exportc: "hive_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage("advance replay")
  try:
    if pendingSeek >= 0:
      player.seekTo(pendingSeek)
      pendingSeek = -1
    else:
      for _ in 0 ..< pendingAdvance:
        advanceReplayFrame(player, @[])
    pendingAdvance = 1
    packet = buildViewerPacket(player.match)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg
    return -1

proc hivePacketPointer(): ptr uint8 {.exportc: "hive_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc hivePacketLength(): cint {.exportc: "hive_packet_len", cdecl.} =
  cint(packet.len)

proc hiveRockPointer(): ptr uint8 {.exportc: "hive_rock_ptr", cdecl.} =
  if rockMask.len == 0: nil else: rockMask[0].addr

proc hiveRockLength(): cint {.exportc: "hive_rock_len", cdecl.} =
  cint(rockMask.len)

proc hiveMismatchTick(): cint {.exportc: "hive_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(player.hashMismatchTick) else: -1

proc hiveTick(): cint {.exportc: "hive_tick", cdecl.} =
  if runtimeLoaded: cint(player.match.tick) else: 0

proc hiveErrorPointer(): ptr uint8 {.exportc: "hive_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc hiveErrorLength(): cint {.exportc: "hive_error_len", cdecl.} =
  cint(lastError.len)

proc hiveStagePointer(): ptr uint8 {.exportc: "hive_stage_ptr", cdecl.} =
  ## Unlike hive_error_*, this stays valid after an allocation-failure abort,
  ## so the page can still report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc hiveStageLength(): cint {.exportc: "hive_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the field bake, the planes and the replay data, while the wasm
  # module stays alive and JS keeps calling hive_frame(). Unwinding main
  # through emscripten's live-runtime exit skips the destructor epilogue
  # entirely, so globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
