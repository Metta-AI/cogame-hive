## Emits the engine-authoritative wire constants the chrome reads, so the
## viewer can never drift from the sim's tick rate or speed ladder.
## Written to `replay-viewer/dist/wire_constants.js` by the viewer build.

import std/strutils
import hive/types

when isMainModule:
  var speeds: seq[string]
  for value in PlaybackSpeeds:
    speeds.add($value)
  echo "window.HIVE_WIRE={",
    "\"fps\":", TargetFps, ",",
    "\"replayFps\":", ReplayFps, ",",
    "\"speeds\":[", speeds.join(","), "],",
    "\"cellPx\":", CellPx, ",",
    "\"cols\":", FieldCols, ",",
    "\"rows\":", FieldRows, ",",
    "\"blockCols\":", BlockCols, ",",
    "\"blockRows\":", BlockRows, ",",
    "\"turnTicks\":240,",
    "\"gameVersion\":\"", GameVersion, "\"};"
