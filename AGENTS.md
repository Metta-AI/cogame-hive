# AGENTS.md — hive

Rules for anyone (human or agent) changing this repo.

## The inviolable property

**Same seed + same resolved doctrine stream ⇒ the same digest at every
keyframe, in the native build AND in the emscripten build.** The browser
viewer re-runs the sim rather than receiving it, so any divergence is a
visible, reported bug (`#mmwarn`).

Consequences you may not work around:

1. **No float, no libm, in the sim step.** `src/hive/{field,pheromones,ants,
   sources,sim}.nim` contain no `sin`, `cos`, `tan`, `atan`, `exp`, `ln`,
   `pow`, `sqrt`, `hypot`, `fmod` and no float arithmetic; `-ffast-math` is
   banned. `tests/test_ants.nim` greps for all of it.
2. **The PCG stream is advanced in a fixed order** — the seat permutation once
   at init, then per tick: sources, then ants in ant order. Adding a draw, or
   drawing conditionally where the old code drew unconditionally, changes every
   later frame. `moveAnt` therefore draws all three candidate noise values
   before it looks at the terrain.
3. **`GameVersion` is the rules gate.** Bump it in `src/hive/types.nim` on any
   change to the integer step, and prepend a
   `GVnn (short rule name): HEADLINE` line to the changelog comment there.
   Re-record `tests/fixtures/golden_digests.json` in the same commit and say so
   in the message.

## Resolution order

`docs/RULES.md` §"Resolution order" is the contract, and `src/hive/sim.nim`
implements it step for step in that order. Reordering steps 4–9 changes the
game. If you must, treat it as a `GameVersion` bump.

## Two name spaces

Prompts, views and event bodies see only `Amber` / `Teal` / `Lime` /
`Magenta`, and those name **corners**, not policies: the seat → nest
permutation is re-drawn from the seed every episode. Real player names exist
only in `replay.names.players`, `results.names` and the viewer's scorebug
plates. `tests/test_view.nim` runs a whole episode and asserts no
`results.names` string appears in any view, event body or prompt.

## Recorded strings

Every string that can reach the replay is truncated on **rune** boundaries,
never bytes: `note` ≤ 140, `say` ≤ 32, `register.policy` ≤ 48,
`fallback.detail` ≤ 200, `register.prompt` ≤ 4000 at the transport. A
byte-truncated multi-byte character renders fine in a browser and fails a
strict JSON parser, which is exactly the bug that loses a replay.

## LLM calls

All four seats' calls go out as **one parallel batch per turn**
(`curly.makeRequests`). Never query seats sequentially — the episode budget
does not survive it. Every wait is bounded: 14 s, then one 6 s retry, then the
`marcher` doctrine and a `fallback` event. The budget guard at the top of each
turn drops the whole remaining match to the scripted layer rather than
overrunning.

## Chrome

`client/chrome_common.js` is paintbot's, **copied unchanged**. Do not edit it
here; fix it upstream and re-copy. `client/replay_broadcast.html` keeps
paintbot's CSS block and every markup id it shipped with — the id list is in
`tests/test_viewer.nim` and the test fails if one disappears. Hive's own
additions are `#nestbug`, `#doctrinebar`, `#warflash` and `#cachebar`, and the
`@media (max-width: 640px)` block that keeps the scorebug legible at 360 px.

## Tests

`ci.yml` runs every `tests/*.nim` as a standalone program, twice (debug and
`-d:release`). Shared helpers live in `tests/support/helpers.nim`, a
subdirectory, so the glob never executes a helper module. **Do not weaken or
delete a test to get green.**

## Artifacts

The end-of-episode write order is load-bearing: broadcast `done` to every seat
(3 s per-seat deadline) → write the replay → write the results. The hosted
worker tears player pods down as soon as `results.json` exists.
