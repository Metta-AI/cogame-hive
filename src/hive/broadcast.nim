## The per-seat view - exactly what a colony can see, and nothing else.
##
## Forked from paintbot's `src/ctf/broadcast.nim` in role: it is the layer
## that turns engine state into the frames a seat and a spectator receive.
## The redaction here is the game's integrity claim made literal: a colony
## learns about a rival only by walking where the rival walked.

import std/[json, strutils]
import types, config, field, pheromones, sources, doctrine, rules, sim

proc rivalRows(match: Sim, colony: int): seq[string] =
  ## `trails.rival[by][bx]`: the max over the other three colonies' FOOD
  ## planes, but ONLY for blocks one of your own ants stood in during the
  ## previous turn. Every other block is `.` - meaning NO READING, not
  ## "no trail".
  result = @[]
  for by in 0 ..< BlockRows:
    var row = newString(BlockCols)
    for bx in 0 ..< BlockCols:
      let index = by * BlockCols + bx
      if match.sensed[colony][index] >= match.turn - 1:
        row[bx] = blockDigit(match.planes.rivalBlockMax(colony, bx, by),
          match.config.pheromoneMax)
      else:
        row[bx] = '.'
    result.add(row)

proc rowsJson(rows: seq[string]): JsonNode =
  result = newJArray()
  for row in rows:
    result.add(%row)

proc meanRangeCells(match: Sim, colony: int): int =
  var total = 0
  for index in 0 ..< match.config.antsPerColony:
    let ant = match.antState[colony * match.config.antsPerColony + index]
    total += chebyshev(int(ant.cx), int(ant.cy),
      match.meadow.nests[colony].cx, match.meadow.nests[colony].cy)
  total div match.config.antsPerColony

proc sourcesSeenJson(match: Sim, colony: int): JsonNode =
  ## Only sources one of your ants has been within one cell of, at their
  ## LAST SEEN amount - never live. A cache you scouted five turns ago may
  ## already be empty.
  result = newJArray()
  for index in 0 ..< match.sources.items.len:
    if index >= match.seenTurn[colony].len:
      break
    if match.seenTurn[colony][index] < 0:
      continue
    let item = match.sources.items[index]
    let near = nearestNest(match.meadow, int(item.cx), int(item.cy),
      match.config.raidRadius)
    result.add(%*{
      "id": int(item.id),
      "block": [int(item.cx) div BlockCells, int(item.cy) div BlockCells],
      "cell": [int(item.cx), int(item.cy)],
      "amount_seen": match.seenAmount[colony][index],
      "seen_turn": match.seenTurn[colony][index],
      "near_nest":
        (if near >= 0: %match.meadow.nests[near].alias else: newJNull())
    })

proc contactsJson(match: Sim, colony: int): JsonNode =
  result = newJArray()
  for rival in 0 ..< Colonies:
    if rival == colony:
      continue
    var blocks = newJArray()
    var count = 0
    for index in 0 ..< BlockCount:
      let hits = match.contactCount[colony][rival][index]
      if hits > 0:
        blocks.add(%[blockX(index), blockY(index)])
        count += hits
    if blocks.len > 0:
      result.add(%*{
        "colony": match.meadow.nests[rival].alias,
        "blocks": blocks,
        "ants": count
      })

proc scoreboardJson*(match: Sim): JsonNode =
  ## PUBLIC: every nest counter is visible to everyone, always, in nest
  ## order. Deliveries are physical and loud.
  result = newJArray()
  for colony in 0 ..< Colonies:
    result.add(%*{
      "colony": match.meadow.nests[colony].alias,
      "delivered": match.delivered[colony]
    })

proc fieldJson*(match: Sim): JsonNode =
  %*{
    "cols": match.meadow.cols,
    "rows": match.meadow.rows,
    "cell_px": match.meadow.cellPx,
    "blocks": [BlockCols, BlockRows],
    "block_cells": BlockCells,
    "rock": rowsJson(match.meadow.rockBlockRows())
  }

proc buildView*(match: Sim, seat: int): JsonNode =
  ## The object that is both the `view` in the turn frame and the tail of the
  ## LLM user message. Aliases only - no real player name reaches it.
  let colony = match.seatNest[seat]
  var carrying = 0
  var scouts = 0
  var atNest = 0
  for index in 0 ..< match.config.antsPerColony:
    let ant = match.antState[colony * match.config.antsPerColony + index]
    if ant.carrying: inc carrying
    if ant.scout: inc scouts
    if match.meadow.inNestPad(colony, int(ant.cx), int(ant.cy)): inc atNest
  let lastDoctrine =
    if match.hasDoctrine[colony]: match.doctrines[colony].toJson()
    else: newJNull()
  %*{
    "turn": match.turn,
    "of": turnsOf(match.config),
    "tick": match.tick,
    "ticks_left": max(0, match.config.episodeTicks - match.tick),
    "seconds_left": match.secondsLeft(),
    "you": {
      "colony": match.meadow.nests[colony].alias,
      "colour": match.meadow.nests[colony].colour,
      "nest": [match.meadow.nests[colony].cx, match.meadow.nests[colony].cy],
      "nest_block": [
        match.meadow.nests[colony].cx div BlockCells,
        match.meadow.nests[colony].cy div BlockCells
      ],
      "ants": match.config.antsPerColony,
      "carrying": carrying,
      "scouts": scouts,
      "at_nest": atNest,
      "delivered": match.delivered[colony],
      "delivered_last_turn": match.deliveredLastTurn[colony],
      "mean_range_cells": meanRangeCells(match, colony),
      "last_doctrine": lastDoctrine
    },
    "field": fieldJson(match),
    "trails": {
      "food": rowsJson(match.planes.blockRows(colony, PlaneFood,
        match.config.pheromoneMax)),
      "home": rowsJson(match.planes.blockRows(colony, PlaneHome,
        match.config.pheromoneMax)),
      "rival": rowsJson(rivalRows(match, colony))
    },
    "sources": sourcesSeenJson(match, colony),
    "contacts": contactsJson(match, colony),
    "scoreboard": scoreboardJson(match),
    "sources_live_total": match.sources.liveCount()
  }

proc viewText*(view: JsonNode): string =
  ## Compact, readable JSON for the LLM user message. Digit grids stay on one
  ## line each so a model can read them as a picture.
  pretty(view, 1).replace("\n\n", "\n")

proc turnFrame*(match: Sim, seat: int, source: DoctrineSource): JsonNode =
  %*{
    "type": "turn",
    "turn": match.turn,
    "tick": match.tick,
    "colony": match.meadow.nests[match.seatNest[seat]].alias,
    "view": buildView(match, seat),
    "doctrine_source": $source
  }
