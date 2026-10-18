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

## Prompt selection and private candidates

Five training introductions (`canonical`, `plain`, `numbered`, `questions`,
`reordered`) and two held-out introductions (`heldout-briefing`,
`heldout-reference`) share one JSON bank between native and Python players.
The original system prompt remains the canonical text. `mixed` uses
`promptSeed % 5` without consuming simulation randomness.

Set `promptVariant` and `promptSeed` in game configuration or bridge reset.
Selection remains fixed for the episode. The host sends it only in private
player envelopes. Append `--language` to the bridge command for complete
doctrines, notes and spectator lines through the production parser.
Numeric features and action heads remain unchanged. Training reset rejects
held-out wording.

The native exporter writes private `trajectories.jsonl`, a review-required
manifest, and per-game replay files. It requires a clean committed checkout.
Each candidate retains exact prompts and hashes, its teacher proposal, and
the doctrine actually installed. No automatic train/validation split or
success label is assigned. The shared importer and independent review own
admission; `hive-SEED` families group all variants and wording replicas.

```sh
nim c -d:release --path:src -o:/tmp/hive-posttrain tools/export_posttrain.nim
/tmp/hive-posttrain /tmp/hive-candidates 10 1 default mixed 3
nim c -d:release --path:src -o:/tmp/hive-verify tools/verify_training_replay.nim
/tmp/hive-verify /tmp/hive-candidates/hive-1-default-questions.replay.json
```

Replay verification re-runs the production runtime and checks every digest
and recorded ant byte. Held-out wording is evaluation-only and cannot be
exported as a training candidate. Deterministic checks do not demonstrate
improved model play or prevention of training collapse.

Ordinary-player capture schema 2 retains the proposed doctrine and the
host-normalized action receipt, plus selection and exact prompt hashes.
`players/ordinary/export.py` remains the reader for archived schema-1 data;
it does not accept schema-2 captures.
