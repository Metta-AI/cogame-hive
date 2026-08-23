# hive

**Four ant colonies foraging one meadow.** Each seat is one policy driving
twenty-four identical ants that see one cell around themselves, drop and smell
two decaying pheromones, and carry food home. There is no combat, no chat, and
no way to steer a single ant. The only levers a colony has are the kernel
weights every ant runs and the heading ants leave the nest with — everything
else it does, it does by painting the ground.

Scored by food returned to the nest, **as a share of all food returned**, so
the game is exactly constant-sum across the four colonies: the only way to
raise your score is to take food a rival did not.

- Rules: [`docs/RULES.md`](docs/RULES.md)
- Wire protocol: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- Watch: <https://softmax.com/hive>

## A policy is just a prompt

Every ten seconds of sim time a colony sets one **doctrine** — nine integers, a
target block and two strings — and the deterministic ant kernel runs it for all
twenty-four bodies at 24 Hz. The LLM is the queen at 0.1 Hz; the kernel is the
colony at 24 Hz. Ninety-six bodies are driven by eighty LLM calls in a whole
episode.

```json
{"scouts": 15, "trail_gain": 78, "poach": 12, "spread": 32,
 "lay_food": 88, "lay_home": 52, "recall": false,
 "focus": [9, 5], "focus_weight": 70,
 "note": "cache at (76,43) is fat and Teal has not found it; pump the road",
 "say": "west road, full pump"}
```

To field your own colony mind, reuse the image and set `PLAYER_PROMPT`:

```bash
coworld upload-policy coworld-hive:latest --name my-hive \
  --run /bin/hive-player --secret-env PLAYER_PROMPT="<your strategy>"
```

`PLAYER_SCRIPTED=marcher` or `PLAYER_SCRIPTED=driftling` plays a built-in
baseline instead — same image, same doctrine schema, no LLM.

## What a spectator sees

The pheromone fields glow as two decaying overlay colours, so each colony's
strategy is literally painted on the ground: the food trail in the colony's hue
brightening as a road pays and dimming as it dies, the home trail a
desaturated layer underneath it. Ant flows read like traffic. Nest counters
pulse on every delivery. When two colonies' roads meet in the same 8 × 8 block
the contested block flashes a hatched two-colour overlay and the banner lane
reads `TRAIL WAR — Amber vs Teal over block 9,5`. Twice a match a four-hundred
unit cache lands dead centre and everybody goes for it.

The replay is a **static wasm bundle**: the viewer re-runs the same integer sim
from the recorded doctrine stream in the browser and verifies its own
re-derivation against the digest in every keyframe. Nothing but the S3 URL is
contacted.

## Layout

```
src/hive.nim              entrypoint (live server / replay server)
src/hive_player.nim       the player: register, listen, exit
src/hive/                 types, config, field, pheromones, ants, sources,
                          sim, rules, doctrine, baselines, llm, state, roster,
                          events, labels, broadcast, global, render, replay,
                          server
replay-viewer/            hive_replay.nim (the wasm module) + the shell
client/                   the broadcast chrome, the board renderer, the art
data/meadow.fieldspec.json  the one authored field
scripts/art/              the committed art generators
tests/                    16 standalone test programs + tests/support
tools/                    the CI smoke, the viewer build hook, wire constants
```

## Build and run

CI is the harness — `.github/workflows/ci.yml` runs every `tests/*.nim` twice
(debug and `-d:release`), builds the image and plays one real episode in raw
Docker from the certification fixture, and builds the static replay bundle.

Locally:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim c -d:release --out:hive src/hive.nim
nim c -d:release --out:hive-player src/hive_player.nim
docker compose build
./tools/ci/docker_smoke.sh coworld-hive:latest
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

## Determinism

Same seed + same resolved doctrine stream ⇒ the same u32 state digest at every
keyframe, in the native build *and* in the emscripten build. The whole step is
integer — no float arithmetic and no libm call appears in the sim, and a
source-grep test enforces it. That is what lets the browser re-derive 220 KiB
of pheromone field per frame from a 240 KB replay and prove it got the same
match.
