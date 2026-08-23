# Hive — wire protocol

Two channels: the player websocket (`hive.player.v1`) and the spectator
channel (`hive.global.v1`, plus the static replay bundle). Both are JSON text
frames. Replay bytes are strict UTF-8 JSON, `hive.replay.v1`.

## Player channel — `hive.player.v1`

`WS /player?slot=N&token=T`. A bad slot or token is **403**; a duplicate
connection on a live slot is **409**.

### player → game (exactly one frame)

```json
{"type": "register",
 "prompt": "<strategy text or empty>",
 "scripted": "marcher" | "driftling" | null,
 "policy": "<free label, <=48 runes>"}
```

`src/hive_player.nim` reads `COWORLD_PLAYER_WS_URL`, `PLAYER_PROMPT`,
`PLAYER_SCRIPTED` and `PLAYER_POLICY_LABEL`, sends that frame, then receives
until `{"done": true, …}` and exits 0. A seat that never registers, or
registers with neither field, is treated as `scripted: "marcher"`.
`PLAYER_SCRIPTED` parsing: `marcher` / `1` / `true` / `yes` → marcher,
`driftling` → driftling, anything else → none. `prompt` over 4000 runes is
**truncated** at the transport, not rejected, and is never written to the
replay or the results.

**Decisions are made server-side.** The game holds the LLM client and asks
every seat's prompt for one doctrine per turn, all four seats in one parallel
batch. The player container is informational after registration.

### game → player

```json
{"type": "welcome", "protocol": "hive.player.v1", "slot": 0,
 "colony": "Amber", "colour": "#f2c14e",
 "turns": 20, "turn_ticks": 240, "ants": 24}
```

```json
{"type": "turn", "turn": 7, "tick": 1680, "colony": "Amber",
 "view": { … }, "doctrine_source": "llm"}
```

```json
{"done": true, "result": { …the results document… }}
```

## The per-seat view

Blocks are 8 × 8 cells, so the block grid is **20 × 11**; block `(bx, by)`
covers cells `cx ∈ [8bx, 8bx+7]`, `cy ∈ [8by, 8by+7]`.

```json
{"turn": 7, "of": 20, "tick": 1680, "ticks_left": 3120, "seconds_left": 130.0,
 "you": {"colony": "Amber", "colour": "#f2c14e", "nest": [16, 12],
         "nest_block": [2, 1], "ants": 24, "carrying": 6, "scouts": 4,
         "at_nest": 3, "delivered": 118, "delivered_last_turn": 21,
         "mean_range_cells": 27, "last_doctrine": { … | null }},
 "field": {"cols": 160, "rows": 88, "cell_px": 8, "blocks": [20, 11],
           "block_cells": 8, "rock": ["....................", … 11 rows … ]},
 "trails": {"food":  ["00000000000000000000", … 11 rows … ],
            "home":  ["01100000000000000000", … 11 rows … ],
            "rival": ["....................", … 11 rows … ]},
 "sources": [{"id": 12, "block": [9, 5], "cell": [76, 43], "amount_seen": 41,
              "seen_turn": 6, "near_nest": null}],
 "contacts": [{"colony": "Teal", "blocks": [[9,5],[10,5]], "ants": 7}],
 "scoreboard": [{"colony": "Amber", "delivered": 118}, … 4 … ],
 "sources_live_total": 9}
```

- `field.rock[by][bx]` is `#` when more than half the block's cells are rock.
- `trails.food` / `trails.home` are digits `0`–`9`:
  `min(9, (meanBlockValue * 10) div (pheromoneMax + 1))` over **your own**
  planes.
- `trails.rival` is the same digit computed as `max` over the other three
  colonies' `F` planes, **but only for blocks where one of your own ants stood
  during the previous turn**. Every other block is `.`, meaning *no reading*,
  not *no trail*. You learn about rivals by walking where they walked.
- `sources[]` lists only sources one of your ants has been within one cell of.
  `amount_seen` and `seen_turn` are as of the last sighting, never live.
  `near_nest` names a colony when the source is within 20 cells of that
  colony's nest centre.
- `contacts[]` lists, per rival, the blocks where your ants shared a cell with
  theirs during the previous turn.
- `scoreboard[]` is **public**: every nest counter is visible to everyone,
  always, in nest order.

**Hidden from a seat:** the positions, headings and carrying state of
individual ants — its own included; rival ant positions; rival pheromone planes
outside sensed blocks; rival `H` planes entirely; the live amount of any source
it has not just seen; the existence of any source it has never seen; every
rival's doctrine, `note`, `say` and prompt; the seat → nest permutation for any
other seat; the episode seed; and the future.

**Hidden from everyone, both in-game name spaces:** the real player names
behind the colony aliases. `Amber` / `Teal` / `Lime` / `Magenta` are the only
names any prompt, view or event body contains.

## Doctrine schema

| Field | Type | Legal values | Repair when violated |
|---|---|---|---|
| `scouts` | int | 0…100 | missing/non-numeric → previous turn's value, or 40 on turn 0; out of range → clamped |
| `trail_gain` | int | 0…100 | as `scouts`, default 50 |
| `poach` | int | 0…100 | as `scouts`, default 15 |
| `spread` | int | 0…100 | as `scouts`, default 40 |
| `lay_food` | int | 0…100 | as `scouts`, default 70 |
| `lay_home` | int | 0…100 | as `scouts`, default 50 |
| `recall` | bool | `true`/`false`; accepts `"true"`/`"false"`/`0`/`1` | → `false`. Forced `false` if the previous turn recalled |
| `focus` | `[int,int]` or null | `bx ∈ 0…19`, `by ∈ 0…10` | out of range → clamped; wrong shape → `null` |
| `focus_weight` | int | 0…100 | as `scouts`, default 0; forced 0 when `focus` is `null` |
| `note` | string | ≤ 140 **runes** | truncated on a rune boundary |
| `say` | string | ≤ 32 **runes** | truncated on a rune boundary |

Parsing is tolerant: markdown fences are stripped, the outermost balanced
`{…}` is taken if the model prefixed prose, numeric strings are accepted for
any integer field, `focus` may be `{"bx":…,"by":…}`, and percentages may be
written `"70%"`. Only when no object carrying at least one recognised doctrine
key can be recovered does the retry, then the fallback, fire. **The resolved,
repaired, clamped doctrine is what is installed and what is recorded** — the
replay never depends on re-running the repair.

Three further caps on strings that reach the replay: `register.policy`
≤ 48 runes, any recorded error text (`fallback.detail`) ≤ 200 runes, and
`register.prompt` ≤ 4000 runes at the transport. **Truncation is on rune
boundaries, never bytes.**

## Results document (closed schema)

All per-seat arrays are length 4 in **slot** order.

```json
{"names": ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"],
 "aliases": ["Amber", "Magenta", "Teal", "Lime"],
 "colours": ["#f2c14e", "#e26db5", "#4ecdc4", "#9fd356"],
 "nests": [[16,12], [143,75], [143,12], [16,75]],
 "policy_kinds": ["llm", "llm", "scripted", "scripted"],
 "scores": [0.31692, 0.28154, 0.22231, 0.17923],
 "win": [true, false, false, false],
 "delivered": [412, 366, 289, 233],
 "harvested": [415, 371, 292, 236],
 "raided_units": [18, 74, 5, 0],
 "raided_from_you": [61, 12, 20, 4],
 "peak_food_trail": [3980, 2440, 4000, 1180],
 "ants": [24, 24, 24, 24],
 "recalls": [1, 0, 2, 0],
 "turns_llm": [20, 19, 0, 0],
 "fallback_turns": [0, 1, 0, 0],
 "fallback_causes": [{"timeout": 0, "parse_error": 0, "transport_error": 0,
                      "no_credentials": 0, "budget_guard": 0}, … 4 … ],
 "total_delivered": 1300,
 "sources_spawned": 76,
 "reason": "complete",
 "end_rule": "full_time",
 "winner": 0,
 "final_tick": 4800,
 "final_turn": 20,
 "seed": 679961}
```

`reason` is one of `complete` / `deadline` / `fault`; `end_rule` is one of
`full_time` / `wall_clock` / `sim_fault` / `host_error`. `winner` is a slot
index `0…3` or `null`.

## Spectator channel — `hive.global.v1`

`WS /global` streams a JSON snapshot on every turn and on every connection:
`{type, game, protocol, t, turn, ticks, turns, fps, speeds, field, colonies,
ants, sources, scoreboard, started, done, connected, events}`. Real player
names appear only in `colonies[].player`, and only when `showPlayerLabels` is
set. `GET /client/global` is a real browser page over the same feed;
`GET /client/player` is the seat's documentation page and never opens the
player socket. `/healthz` and `/global` keep answering for a 20 s shutdown
grace after the artifacts are written.

## Replay bytes — `hive.replay.v1`

Strict UTF-8 JSON. The **input log is the doctrine stream**, because the ant
kernel is a pure function of `(seed, field, doctrines)` — which is why the
replay is small and why the viewer can re-derive the pheromone field.

```json
{"protocol": "hive.replay.v1",
 "format_version": 1,
 "game_version": "1",
 "seed": 679961,
 "config": { …the resolved game config, tokens excluded… },
 "field": { …data/meadow.fieldspec.json inlined verbatim, pre-mirroring… },
 "seat_nests": [0, 3, 1, 2],
 "names": {"players": [...], "aliases": [...], "policy_kinds": [...],
           "colours": [...]},
 "ticks_per_second": 24, "turn_ticks": 240, "tick_count": 4800,
 "doctrines": [{"turn": 0, "seat": 0, "source": "llm", "latency_ms": 4120,
                "scouts": 55, …, "note": "…", "say": "…"}, … ],
 "keyframes": [{"t": 0, "d": 2947483111, "del": [0,0,0,0], "car": [0,0,0,0],
                "src": [[3,76,43,60], … ]}, … every 24 ticks … ],
 "ants_b64": "<base64 of keyframeCount x 96 x 3 bytes: (cx u8, cy u8,
              state u8) per ant per keyframe, ants in global index order>",
 "events": [ … ],
 "results": { … }}
```

Ant state codes: `0` searching forager, `1` searching scout, `2` carrying,
`3` at nest, held by recall. `src` rows are `[id, cx, cy, amount]`.

### Event vocabulary

Every record carries `t` (tick), and `turn` where meaningful.

| `type` | Fields |
|---|---|
| `match_start` | `t`, `seed`, `field`, `colonies`, `ants_per_colony`, `episode_ticks` |
| `turn_start` | `t`, `turn`, `delivered`, `sources_live` |
| `doctrine` | `t`, `turn`, `seat`, `colony`, `source`, `latency_ms`, the nine doctrine fields, `note`, `say` |
| `fallback` | `t`, `turn`, `seat`, `attempt`, `cause`, `detail` |
| `budget_guard` | `t`, `turn`, `remaining_s` |
| `recall` | `t`, `turn`, `colony`, `ants_recalled` |
| `source_spawn` | `t`, `kind`, `orbit`, `sources`, `near` |
| `source_gone` | `t`, `source`, `cell`, `cause`, `taken` |
| `harvest` | `t`, `s`, `c`, `u` |
| `deliver` | `t`, `c`, `n`, `s`, `r` |
| `raid` | `t`, `colony`, `victim`, `source`, `units` |
| `trail_war` | `t`, `block`, `colonies`, `strengths` |
| `end` | `t`, `reason`, `end_rule`, `delivered`, `scores`, `winner` |

## Runtime contract

`bitworld/runtime`: `COGAME_CONFIG_URI`, `COGAME_RESULTS_URI`,
`COGAME_SAVE_REPLAY_URI`, `COGAME_LOAD_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI` and `COGAME_METRICS_URI` —
the last two `file://`-only and loudly rejected otherwise. The end-of-episode
write order is: broadcast `done` to every seat with a 3 s per-seat deadline →
write the replay → write the results.

The game container does **not** receive `COWORLD_TIMEOUT_SECONDS`; 1200 s is
assumed. Every wait is bounded: two LLM attempt deadlines (14 s then 6 s), one
per-turn budget of 22 s, `playerConnectTimeoutSeconds` on the connect wait, a
3 s per-seat deadline on the final done-broadcast, and a 660 s engine stop.
