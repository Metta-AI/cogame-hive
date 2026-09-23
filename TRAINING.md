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

## Metta post-training

The exporter records the acting seat's hosted system and user messages and
a `marcher` doctrine accepted by the game's parser. It keeps complete games
in one train or validation split:

```sh
for variant in default sprint; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/hive-${variant}" 10 1 "$variant"
done
```

From a Metta checkout, train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/hive-default \
  --output /tmp/hive-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten games yielded 640 training and 160 validation decisions for Default,
and 384 training and 96 validation decisions for Sprint. All 1,280 examples
fit a Qwen tokenizer at 4,096 tokens. One CPU optimizer step per variant
with a local tiny model reduced held-out loss. These runs verify the data
path and distill the scripted baseline; they do not establish stronger play.
