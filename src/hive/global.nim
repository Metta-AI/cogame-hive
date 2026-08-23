## The spectator channel: the `/global` snapshot and the `/client/global`
## page's data feed.
##
## Forked from paintbot's `src/ctf/global.nim` in role only - the CTF art and
## the sprite atlas are gone. What survives is the idea that the live
## spectator stream and the replay viewer read the SAME derived state, so a
## bug shows up in both.

import std/json
import types, config, field, doctrine, sim, rules, broadcast

proc coloniesJson*(match: Sim, playerNames: seq[string],
    showPlayerLabels: bool): JsonNode =
  ## Real player names ride here for the SPECTATOR view only; every in-game
  ## surface sees the alias.
  result = newJArray()
  for seat in 0 ..< Colonies:
    let colony = match.seatNest[seat]
    var carrying = 0
    for index in 0 ..< match.config.antsPerColony:
      if match.antState[colony * match.config.antsPerColony + index].carrying:
        inc carrying
    result.add(%*{
      "seat": seat,
      "nest": colony,
      "alias": match.meadow.nests[colony].alias,
      "colour": match.meadow.nests[colony].colour,
      "cell": [match.meadow.nests[colony].cx, match.meadow.nests[colony].cy],
      "player":
        (if showPlayerLabels and seat < playerNames.len: %playerNames[seat]
         else: newJNull()),
      "delivered": match.delivered[colony],
      "carrying": carrying,
      "scouts": match.coefficients[colony].scoutCount,
      "doctrine": match.doctrines[colony].toJson(),
      "doctrine_source": $match.doctrineKinds[colony]
    })

proc antsJson*(match: Sim): JsonNode =
  result = newJArray()
  for g in 0 ..< match.antsTotal():
    result.add(%[
      int(match.antState[g].cx),
      int(match.antState[g].cy),
      int(match.antStateCode(g)),
      g div match.config.antsPerColony
    ])

proc sourcesJson*(match: Sim): JsonNode =
  result = newJArray()
  for item in match.sources.items:
    if item.alive:
      result.add(%*{
        "id": int(item.id),
        "cell": [int(item.cx), int(item.cy)],
        "amount": int(item.amount),
        "spawn_amount": int(item.spawnAmount)
      })

proc globalSnapshot*(
  match: Sim,
  playerNames: seq[string],
  started, done: bool,
  connected: seq[bool],
  recentEvents: int = 40
): JsonNode =
  var events = newJArray()
  let start = max(0, match.events.items.len - recentEvents)
  for index in start ..< match.events.items.len:
    events.add(match.events.items[index])
  %*{
    "type": "state",
    "game": "hive",
    "protocol": "hive.global.v1",
    "t": match.tick,
    "turn": match.turn,
    "ticks": match.config.episodeTicks,
    "turns": turnsOf(match.config),
    "fps": TargetFps,
    "speeds": @PlaybackSpeeds,
    "field": fieldJson(match),
    "colonies": coloniesJson(match, playerNames, match.config.showPlayerLabels),
    "ants": antsJson(match),
    "sources": sourcesJson(match),
    "scoreboard": scoreboardJson(match),
    "started": started,
    "done": done,
    "connected": connected,
    "events": events
  }
