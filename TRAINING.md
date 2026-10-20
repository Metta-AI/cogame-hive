# Training

Both certified Hive variants use the same headless simulator and redacted
player view. Build the persistent numeric bridge and play complete matches:

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/hive-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/hive-train-bridge
```

Pass the binary, `coworld_manifest_template.json`, `default` or `sprint`,
and `data/meadow.fieldspec.json`
to Metta's `recipes.external.coworld_metta_rl.train` or
`recipes.external.coworld.train`. Use `players=4` and a finite
`total_timesteps`. The bridge has 1,575 numeric features and ten action heads
for the six doctrine percentages, recall, focus block, and focus weight.
Focus weight zero means no focus. All four seats decide against the same
pre-turn state. The numeric observation is built from `buildView`, which
limits rival trails to blocks the acting colony sensed.

The scripted `marcher` baseline is available through the bridge's `teacher`
request. The hosted language player can still write notes and a short public
line; the numeric bridge uses empty strings for those fields.

## Prompt selection and complete exports

The `hive-rules-v3` JSON bank shares complete rule presentations between Nim
and Python players. Five training wordings are `canonical`, `plain`, `numbered`,
`questions`, and `reordered`; `heldout-briefing` and `heldout-reference` are
reserved for evaluation. The canonical briefing corrects the central-cache count for sprint. The doctrine
schema stays exact. Alternatives use independent explanations, not reordered paragraphs.

`mixed` requires an independent nonnegative `promptSeed` and selects seed modulo
five. Selection stays fixed throughout an episode; teacher exports cycle
wordings independently within training and validation. Episode IDs include
requested selection, resolved wording, and prompt seed to distinguish matched collections. Training resets and exports reject held-out wording.
The game sends selection to ordinary players; deploy game and players together.

```sh
nim c -d:release --path:src -o:/tmp/hive-posttrain tools/export_posttrain.nim
/tmp/hive-posttrain /tmp/hive-dataset 10 1 default mixed 0
```

The original train.jsonl, validation.jsonl, and manifest format is retained.
Every fifth game is validation; `hive-SEED` groups mode and wording replicas.
Prompt metadata includes hashes of actual messages. Both variants retain their
published budgets. See the [ordinary-player workflow](docs/TRAINING.md).

Deterministic checks establish preserved gameplay, not stronger learned play.
Compare canonical-only and mixed training using identical initialization,
optimizer, decision budgets, opponents, and scenario families. Freeze training
choices before evaluating held-out wordings; report score spread, invalid
outputs, fallbacks, and incomplete games, then inspect paired regressions.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.
