## Re-run the exported doctrine stream through the production replay runtime.
import std/[json, os]
import hive/replay

let data = parseReplayBytes(readFile(paramStr(1)))
let player = initReplayRuntime(data)
var rebuilt: seq[uint8]
var seenTick = -1
while not player.finished():
  advanceReplayFrame(player, @[])
  if player.match.lastDigestTick != seenTick:
    seenTick = player.match.lastDigestTick
    for value in player.match.lastKeyframeAnts: rebuilt.add(value)
doAssert player.hashMismatchTick == -1
doAssert rebuilt == data.antBytes
doAssert player.match.tick == data.tickCount
echo $(%*{"replay_verified": true, "ticks": data.tickCount})
