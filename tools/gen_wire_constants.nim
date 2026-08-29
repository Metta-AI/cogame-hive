## Emits the engine-authoritative wire constants the chrome reads, so the
## viewer can never drift from the sim's tick rate or speed ladder.
## Written to `replay-viewer/dist/wire_constants.js` by the viewer build.

import std/strutils
import hive/types

when isMainModule:
  var speeds: seq[string]
  for value in PlaybackSpeeds:
    speeds.add($value)
  # 0.5 is the replay-only half speed (command '5'): the viewer's accumulator
  # spends a sim tick every other frame, so it never touches the engine's
  # integer PlaybackSpeeds ladder and rides ahead of it here.
  echo "window.HIVE_WIRE={",
    "\"fps\":", TargetFps, ",",
    "\"replayFps\":", ReplayFps, ",",
    "\"speeds\":[0.5,", speeds.join(","), "],",
    "\"cellPx\":", CellPx, ",",
    "\"cols\":", FieldCols, ",",
    "\"rows\":", FieldRows, ",",
    "\"blockCols\":", BlockCols, ",",
    "\"blockRows\":", BlockRows, ",",
    "\"turnTicks\":240,",
    "\"gameVersion\":\"", GameVersion, "\"};"
