## The two name spaces.
##
## In-game - prompts, views, event bodies - a colony is only ever `Amber`,
## `Teal`, `Lime` or `Magenta`, and those name CORNERS, not policies: the
## seat -> nest permutation is re-drawn from the episode seed every episode.
## Real player names exist only in `replay.names.players`, `results.names` and
## the viewer's scorebug plates.

import types

const
  AliasNames*: array[Colonies, string] = ["Amber", "Teal", "Lime", "Magenta"]
  AliasColours*: array[Colonies, string] =
    ["#f2c14e", "#4ecdc4", "#9fd356", "#e26db5"]

proc seatPermutation*(rng: var Pcg): array[Colonies, int] =
  ## A permutation of [0, 1, 2, 3] drawn from the episode seed: `result[seat]`
  ## is that seat's nest. Fisher-Yates, integer draws only, advanced once at
  ## init so every later draw is a function of the seed and the doctrines.
  for index in 0 ..< Colonies:
    result[index] = index
  for index in countdown(Colonies - 1, 1):
    let pick = rng.rnd(index + 1)
    let swap = result[index]
    result[index] = result[pick]
    result[pick] = swap

proc invert*(permutation: array[Colonies, int]): array[Colonies, int] =
  ## `result[nest]` is the seat sitting at that nest.
  for seat in 0 ..< Colonies:
    result[permutation[seat]] = seat
