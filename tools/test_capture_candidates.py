"""Export ten complete native captures, then reject corrupted player evidence."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("panel", type=Path)
parser.add_argument("verifier", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
runs = sorted(args.panel.iterdir())
revision = json.loads((runs[0] / "private/host.jsonl").read_text().splitlines()[0])[
    "source_revision"
]
command = [sys.executable, str(ROOT / "players/ordinary/candidates.py")]
options = [
    *map(str, runs),
    "--source-revision",
    revision,
    "--replay-verifier",
    str(args.verifier),
]
subprocess.run([*command, str(args.output), *options], check=True)
manifest = json.loads((args.output / "manifest.json").read_text())
assert manifest["review_required"] is True and manifest["seed_families"] == 10
rows = [
    json.loads(line)
    for line in (args.output / "trajectories.jsonl").read_text().splitlines()
]
assert sum(row["event_type"] == "episode" for row in rows) == 10
assert {row["seed_family"] for row in rows if row["event_type"] == "episode"} == {
    f"hive-{seed}" for seed in range(1, 11)
}
for row in rows:
    if row["event_type"] == "decision":
        assert row["attempts"][0]["origin"] == "unknown"
        assert (
            row["executed_action"]["scouts"]
            != json.loads(row["attempts"][0]["response"])["scouts"]
        )
assert (args.output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
artifact = runs[0] / "policy_artifact_0.zip"
original = artifact.read_bytes()
with zipfile.ZipFile(artifact) as archive:
    trajectory = json.loads(archive.read("trajectory.json"))
trajectory["decisions"][0]["prompt_template"]["system_sha256"] = "0" * 64
try:
    with zipfile.ZipFile(artifact, "w") as archive:
        archive.writestr("trajectory.json", json.dumps(trajectory))
    rejected = args.output.with_name(args.output.name + "-corrupt")
    result = subprocess.run(
        [*command, str(rejected), *options], capture_output=True, text=True
    )
    assert result.returncode != 0 and "prompt wording or hashes differ" in result.stderr
    assert not (rejected / "manifest.json").exists()
finally:
    artifact.write_bytes(original)
print(
    "Ten native candidate families, normalized actions, and hash corruption rejection PASS"
)
