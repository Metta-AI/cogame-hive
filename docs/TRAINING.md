# Hive training

Build `Dockerfile.ordinary-player` and seat the image through the normal
Coworld player interface. The certification fixture keeps its bundled
marcher players. An ordinary player uses the same authenticated JSON WebSocket.
Each turn it receives a private view and constructs its own prompt and complete
doctrine candidates. The game parses and records its returned doctrine.

The default player chooses marcher. `HIVE_ADAPTER_DIR` loads
a packaged trained adapter with its matching local base model, PyTorch,
Transformers, and PEFT. `PLAYER_PROMPT` remains private to the seat.

Set `HIVE_CAPTURE_TRAINING=1` and `HIVE_SOURCE_REVISION` to upload accepted
decisions as the standard player artifact. The game sends an acceptance
receipt after parsing each decision and a final results frame before it
writes results. Export at least two complete seed runs:

```sh
python3 players/ordinary/export.py /tmp/hive-dataset \
  /tmp/hive-run-14 /tmp/hive-run-15 \
  --source-revision <game-source-sha> --source scripted
```

The exporter splits whole seeds into train and validation, rejects deadline
and fault endings, and checks source revision and game scores. Output uses
`hive-doctrine-v1`, matching the native exporter:

```sh
nim c -d:release --path:src -o:/tmp/hive-posttrain tools/export_posttrain.nim
/tmp/hive-posttrain /tmp/hive-data 10 1 default
```

The other certified variant is `sprint`. Both methods emit Metta
post-training JSONL with player-constructed prompts and complete accepted actions.
Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for training configuration and adapter packaging.

## Episode wording

The game supplies prompt selection privately. The player renders the shared
`hive-rules-v3` bank, varying complete rule explanations and ordering while
keeping reply syntax fixed. Deploy game and ordinary player together.

Accepted captures retain the original version-one artifact format. New rows
include selection metadata and actual prompt hashes; existing stored rows
without metadata remain readable. Held-out wording is rejected for training.
Local private artifacts use owner-only permissions. See [selection and teacher
exports](../TRAINING.md).
