# Hive training

Build `Dockerfile.ordinary-player` and seat the image through the normal
Coworld player interface. Each turn receives a private view and the fixed
episode prompt selection. The game parses the returned doctrine and sends
its normalized action in the private receipt. See [the training guide](../TRAINING.md)
for the shared five-wording bank, held-out wordings and numeric/language bridge.

The default player chooses marcher. `HIVE_ADAPTER_DIR` loads a packaged
trained adapter with its matching local base model, PyTorch, Transformers,
and PEFT. `PLAYER_PROMPT` remains private to the seat.

Set `HIVE_CAPTURE_TRAINING=1`, `HIVE_SOURCE_REVISION` and the standard
`COWORLD_PLAYER_ARTIFACT_UPLOAD_URL` to retain schema-2 player evidence.
It contains exact prompts, hashes, proposed replies, HTTP bodies when used,
submission counts, and accepted or rejected host receipts. A rejected proposal
remains distinct from the scripted action that executes.

For a qualified native host build, first commit the source and confirm
`git status --porcelain` is empty. Compile with
`-d:HiveSourceRevision=<full-commit> -d:HiveSourceDirty=false`.
Unqualified builds default to unknown source and dirty status.
Set `HIVE_CAPTURE_DIR` to a private directory. The host writes `host.jsonl`
with actual native attempts, normalized decisions and the applied doctrine
log. These files never enter spectator frames or public replay data.

Keep each complete run containing `config.json`, `results.json`, `replay.json`,
`private/host.jsonl`, and four `policy_artifact_SLOT.zip` files together.
Export at least ten distinct seed families with the production replay verifier:

```sh
nim c -d:release --path:src -o:/tmp/hive-verify tools/verify_training_replay.nim
python3 players/ordinary/candidates.py /tmp/hive-candidates /tmp/hive-runs/episode-* --source-revision <full-commit> --replay-verifier /tmp/hive-verify
```

The exporter checks every seat and applied decision, source identity,
completion, hashes and receipts. It re-simulates the recorded doctrine stream
and checks every digest and ant byte. Held-out wording cannot enter training
candidates. Candidate output has no automatic labels or train/validation split;
independent review and the shared Metta importer own admission. All mechanics
and wording replicas share `hive-SEED` families. Unattested model origins remain
`unknown`, including local HTTP fixtures.

`players/ordinary/export.py` reads archived schema-1 captures only. Its historical
automatic split is not the schema-2 candidate workflow. The native scripted
exporter is documented in [TRAINING.md](../TRAINING.md).

Run `tools/test_native_prompts.py --help` for complete games through both
player protocols. `--candidate-panel` runs ten ordinary-player seed families;
`tools/test_capture_candidates.py` exports them and rejects a corrupted hash.
These deterministic fixtures establish evidence correctness, not improved
model performance or prevention of training collapse.
