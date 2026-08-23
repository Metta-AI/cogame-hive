# Hive — rules

Four ant colonies forage one shared meadow. Each seat is **one policy driving
twenty-four identical ants**. An ant sees one cell in every direction and
nothing else. There is no combat, no chat, and no way for a colony's policy to
steer an individual ant. Everything else the colony does, it does by painting
the ground.

## The field

- **Grid.** 160 × 88 cells, 8 px a cell, so the board is 1280 × 704 px. Cell
  `(cx, cy)` occupies pixels `[cx*8, cx*8+7] × [cy*8, cy*8+7]`; origin
  top-left, +x right, +y down.
- **Rock.** Static impassable cells, authored in `data/meadow.fieldspec.json`
  as rectangles, discs and polygons. The loader ORs in all three mirror
  images, so the mask is invariant under `cx → 159 − cx` and `cy → 87 − cy`.
  Rock blocks movement and holds no pheromone. Rock is **not secret** — the
  terrain is in every seat's observation, always.
- **Nests.** Four, one per corner, each a 5 × 5 cell pad (Chebyshev radius 2
  around its centre):

  | Nest | Centre cell | Colony | Hex |
  |---|---|---|---|
  | `N0` | (16, 12) | Amber | `#f2c14e` |
  | `N1` | (143, 12) | Teal | `#4ecdc4` |
  | `N2` | (16, 75) | Lime | `#9fd356` |
  | `N3` | (143, 75) | Magenta | `#e26db5` |

  The four centres are the orbit of (16, 12) under both mirrors, so the set is
  exactly symmetric: every colony has one horizontal neighbour, one vertical
  neighbour, one diagonal and one equidistant centre. **Colour is a property of
  the nest, never of the seat** — the seat → nest assignment is a permutation
  of `[0,1,2,3]` drawn from the episode seed and re-drawn every episode.
- **Ants.** 24 a colony, 96 on the field. An ant has a cell, one of eight
  headings (`0 = E`, counter-clockwise in 45° steps), a carrying flag and, when
  carrying, the id of the source the unit came from. Ants never die, never
  fight and **never block each other**; only rock and the field edge block
  movement. An ant acts once every 2 ticks: ant `g = nestIndex * 24 + antIndex`
  acts on tick `t` iff `(t + g) mod 2 == 0`.
- **Pheromones.** Two planes a colony — `F` (food trail) and `H` (home trail) —
  a `uint16` a cell, `0 … 4000`. Every 8 ticks every non-zero cell becomes
  `p ← (p * 248) shr 8`, and anything under 4 becomes 0. Half-life ≈ 175 ticks
  ≈ 7.3 s: an unmaintained trail is gone in about half a minute and a trail
  that pays keeps itself alive.
- **Food.** A source is `{id, cell, amount, spawn_tick, life_ticks}`.
  - **Orbits.** Every 240 ticks, if fewer than 3 orbits are alive, one new
    orbit spawns: a cell drawn inside the top-left quadrant (rejected unless it
    is free floor at Chebyshev distance ≥ 14 from every nest centre and ≥ 3
    from every live source) plus its three mirror images. Each of the four
    sources carries 60 units and lives 1440 ticks.
  - **Bonanzas.** At ticks 1200 and 3600, four sources spawn on the exact
    centre block — (79, 43), (80, 43), (79, 44), (80, 44) — each with 100 units
    and a 900-tick life. Equidistant from all four nests, and the reason the
    middle of the meadow becomes a battlefield twice per match.

## The ant kernel

An acting ant at cell `c` with heading `d` considers exactly **three**
candidates: forward-left `d+7`, forward `d`, forward-right `d+1`. It cannot
reverse except on a pickup or a stall. Candidates that are rock or off-field
are discarded; if all three are, the ant turns 90° and does not move.

For a **searching** ant, candidate `k` scores, in `int32`:

```
score(k) = ((alphaFood  * F_own[k])      shr 4)
         + ((alphaRival * F_rivalMax[k]) shr 4)
         - ((alphaHome  * H_own[k])      shr 4)
         + (if k is the forward cell: alphaFwd else 0)
         + 900 * foodAdjacent(k)
         + rnd(0 .. alphaNoise - 1)
```

`F_rivalMax[k]` is the largest food-trail value among the other three colonies
at `k` — an ant literally smells a rival's road under its feet.
`foodAdjacent(k)` is 1 when a live source with `amount > 0` sits in `k` or one
of `k`'s eight neighbours.

For a **carrying** ant:

```
score(k) = ((betaHome * H_own[k]) shr 4)
         + (if within 12 cells of the nest AND k reduces the Chebyshev
            distance to it: 1200 else 0)
         + (if k is the forward cell: 260 else 0)
         + rnd(0 .. 31)
```

**Path integration is deliberately short-ranged.** Beyond 12 cells a laden ant
has no idea where home is and must ride the home trail its nestmates laid.
That is what makes `H` load-bearing rather than decorative.

Highest score wins; ties break in candidate order **left, forward, right**.

## The doctrine

Every 240 ticks (10 s) each colony sets one doctrine, and the kernel runs it
for all 24 bodies at 24 Hz:

```json
{"scouts": 15, "trail_gain": 78, "poach": 12, "spread": 32,
 "lay_food": 88, "lay_home": 52, "recall": false,
 "focus": [9, 5], "focus_weight": 70,
 "note": "<=140 runes", "say": "<=32 runes"}
```

It compiles to the kernel's integer coefficients by this exact table:

| Coefficient | From the doctrine | Range |
|---|---|---|
| `alphaFood` | `trail_gain * 4` | 0 … 400 |
| `alphaRival` | `poach * 3` | 0 … 300 |
| `alphaHome` | `spread * 3` | 0 … 300 |
| `alphaFwd` | `320 - spread * 2` | 320 … 120 |
| `alphaNoise` | `40 + (100 - trail_gain) * 4` | 40 … 440 |
| `betaHome` | `200 + trail_gain * 2` | 200 … 400 |
| `layFood` | `40 + lay_food * 3` | 40 … 340 |
| `layHome` | `20 + lay_home * 2` | 20 … 220 |
| `scoutCount` | `(scouts * 24 + 50) div 100` | 0 … 24 |

The first `scoutCount` ants by index are **scouts** for that turn: they run the
same kernel with `alphaFood div 4`, `alphaRival = 0` and doubled noise, so they
ignore the roads and wander. Their deposits are unchanged, so the instant a
scout finds food it becomes a carrier and lays a full-strength trail home. That
is the recruitment moment.

`recall: true` makes every ant drop its road, walk home on the carrying kernel
and hold in the nest pad until a turn arrives with `recall: false`. It may not
run two turns in a row.

`focus` is the only colony-level steering that exists, and it acts at the nest
mouth on a departing body: a released ant takes the bearing toward the focus
block with probability `focus_weight` percent, else a uniform draw over the
eight headings.

## Resolution order (exact, per tick, no exceptions)

1. **Turn clock.** `turn = t div 240`. On a turn boundary: install the
   doctrines, clear each colony's sensed block map, roll
   `delivered_last_turn`, emit `turn_start` and one `doctrine` per seat.
2. **Source lifecycle.** Spawn an orbit / the bonanzas, then retire (ascending
   source id) every source at zero or past its life.
3. **Activation set.** Ant `g` acts iff `(t + g) mod 2 == 0`. Steps 4–9 run in
   ant order.
4. **Recall modifier.**
5. **Deposit.** Carrying → `F_own += layFood`; searching → `H_own += layHome`,
   saturating at 4000. Also stamps `sensed[colony][block]`.
6. **Pickup.** Own cell, then N, NE, E, SE, S, SW, W, NW, lowest live source id
   wins: one unit, `carrying = true`, about-face, skip the move.
7. **Delivery.** A carrying ant inside its **own** pad delivers one unit. A
   rival's pad does nothing.
8. **Move.** The kernel above.
9. **Release.** A delivering ant, and any non-carrying ant standing in its own
   pad that did not move, gets a new heading.
10. **Trail-war scan** every 48 ticks.
11. **Pheromone decay** every 8 ticks.
12. **Harvest flush** every 24 ticks.
13. **Keyframe** every 24 ticks (tick, the 96 ants, the counters, the live
    sources, the u32 state digest).
14. **Turn snapshot** in memory, so a backward seek in the viewer replays at
    most one turn.
15. **End check.**

## Scoring

```
delivered[s]  = units this seat's ants carried into their own nest pad
total         = delivered[0] + delivered[1] + delivered[2] + delivered[3]
score[s]      = delivered[s] / total     if total > 0
score[s]      = 0.25                     if total == 0
```

**Higher is better.** `score ∈ [0, 1]` and `sum(score) == 1.0` exactly for
every legal outcome — the game is exactly constant-sum across the four
colonies, so the only way to raise your score is to take food a rival did not.
`winner` is the slot with the unique maximum, or `null` on a tie.

## End conditions

| `reason` | `end_rule` | When |
|---|---|---|
| `complete` | `full_time` | All 4800 ticks simulated. The normal ending. |
| `deadline` | `wall_clock` | The 660 s engine stop tripped first. Scores the counters as they stand; shares still sum to 1.0. |
| `fault` | `sim_fault` | An invariant guard tripped. All scores 0.25, `winner: null`. |
| `fault` | `host_error` | An unexpected server-side exception. Same treatment. |

A seat that never connects does **not** end the episode: its colony is driven
by the `marcher` baseline for the whole match, the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, and the match plays to full time.

## Determinism

Same seed + same resolved doctrine stream ⇒ the same digest at every keyframe,
in the native build *and* in the emscripten build. It holds because the whole
step is integer: no `sin`, `cos`, `tan`, `atan`, `exp`, `ln`, `pow`, `sqrt`,
`hypot`, `fmod` or float arithmetic of any kind appears in the sim step, and
`-ffast-math` is banned. A source-grep test enforces both.
