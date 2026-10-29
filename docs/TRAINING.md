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
and fault endings, and checks source revision and game scores. Matched wording
runs may share a seed and stay in the same split. Episode IDs include a hash
of the complete captured trajectory; duplicate captures are rejected. This
also distinguishes stored version-one captures without prompt metadata. Output uses
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

## Native HTTP evidence

Set `COGAME_SAVE_TRAJECTORY_URI` to a private file URI to record the central Nim client’s actual model requests, raw HTTP response bytes, response headers and call IDs, retries, private actor views and actual installed doctrine records. Leave it unset for the original no-capture path. Private destinations must differ from public replay/results destinations. Publication failures remain visible without changing public gameplay.

Targets require the native-selected JSON object to satisfy strict grammar, scalar Unicode and exact supplied-field/type equality with the installed command. Supported fences and omitted native defaults remain eligible; repaired fields are rejected without rewriting the original response. Consumed note/say strings also receive an atomic native Unicode check before state writes, including typed callers. Request/response/header/view and episode limits produce explicit gaps. Batch elapsed time is retained separately; individual call latency remains unknown.

Run the actual native HTTP/WebSocket fixture with `python tools/ci/native_capture_system.py --help`. Reconstruct recorded episodes with `tools/check_native_capture.nim CONFIG TRAJECTORY REPLAY [OPERATORS_JSON]` compiled against this repository. For real policies, supply a private JSON array of four frozen operator strings, in seat order; do not infer them from the captured request. Omitting that file retains the `native fixture only` fixture default. The fixture accepts `--operator-prompt` and records its operators separately, so a different supplied operator can also be checked and a mismatched one rejected. Fixture UUIDs are synthetic and confer no authenticated receipt or teacher admission. The older ordinary-player JSON action export is not original provider evidence.

Hive has one authored meadow family. Seed, horizon, wording and seat aliases do not establish independent training/validation worlds. Hosted receipt admission, strategic quality, image qualification and learning remain separate gates.

Reproduce with Nim 2.2.4 and the locked dependencies, using an existing Python
environment with `websockets` installed (no provider credentials):

```sh
nim c -d:release --out:dist/hive-capture src/hive.nim
nim c -d:release --out:dist/hive-player src/hive_player.nim
env -i PATH="$PATH" HOME="$HOME" python tools/ci/native_capture_system.py \
  --game dist/hive-capture --player dist/hive-player \
  --output dist/native-proof --capture --mode mixed
nim c -d:release --out:dist/hive-check tools/check_native_capture.nim
dist/hive-check dist/native-proof/config.json \
  dist/native-proof/trajectory.jsonl dist/native-proof/replay.json
```

The system harness also supports `--mode boundary` for a configured two-turn
component: a real external WebSocket action with invalid consumed Unicode is
retried, while central model seats exhaust malformed replies and use the native
fallback. Add `--sink-failure` to verify a private write error preserves public
results, or `--forensic-metadata` to retain invalid provider diagnostics as exact
base64 while excluding that target. These components do not establish full
ordinary-episode completion. The native checker independently reconstructs all
private views, prompts, installed doctrines, keyframes, ant frames and native
scores; event failure counters are not independently reconstructed.

Response headers are the actual native HTTP library's parsed map, not a
lossless header-wire copy. Only safe request headers are retained. Fixture
source/image/policy identities are local diagnostics; authenticated hosted
receipt, policy and immutable image joins still require independent admission.
