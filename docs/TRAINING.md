# Hive training

Build `Dockerfile.ordinary-player` and seat the image through the normal
Coworld player interface. The certification fixture keeps its bundled
marcher players. An ordinary player registers `external: true` on the same
authenticated JSON WebSocket. Each turn it receives the game's exact private
system and user prompts and two complete doctrine candidates. The game
parses and records its returned doctrine through the existing replay path.

The default player chooses marcher. `HIVE_JEV=1` asks Jev through the System
One sidecar to choose between marcher and driftling. `HIVE_ADAPTER_DIR` loads
a packaged trained adapter with its matching local base model, PyTorch,
Transformers, and PEFT. `PLAYER_PROMPT` remains private to the seat.

Set `HIVE_CAPTURE_TRAINING=1` and `HIVE_SOURCE_REVISION` to upload accepted
decisions as the standard player artifact. The game sends an acceptance
receipt after parsing each decision and a final results frame before it
writes results. Export at least two complete seed runs:

```sh
python3 players/ordinary/export.py /tmp/hive-dataset \
  /tmp/hive-run-14 /tmp/hive-run-15 \
  --source-revision <game-source-sha> --source canned
```

The exporter splits whole seeds into train and validation, rejects deadline
and fault endings, and checks source revision and game scores. Output uses
`hive-doctrine-v1`, matching the native exporter:

```sh
nim c -d:release --path:src -o:/tmp/hive-posttrain tools/export_posttrain.nim
/tmp/hive-posttrain /tmp/hive-data 10 1 default
```

The other certified variant is `sprint`. Both methods emit Metta
post-training JSONL with exact hosted prompts and complete accepted actions.
From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/hive-dataset --output /tmp/hive-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```
