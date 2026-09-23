"""Play both certified Hive variants through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    field = manifest.parent / "data" / "meadow.fieldspec.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant, str(field)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"hive-{variant}-{teacher}", "players": 4})
        widths = set()
        batch_views = None
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [101] * 6 + [2, 20, 11, 101]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            if observation["seat"] == 0:
                batch_views = (view["turn"], view["tick"], view["scoreboard"])
                if decisions == 0:
                    assert all(set(row) == {"."} for row in view["trails"]["rival"])
            else:
                assert (view["turn"], view["tick"], view["scoreboard"]) == batch_views
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            assert all(action[head["name"]] in head["choices"] for head in heads)
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 80
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1", "2", "3"}
        assert all(0 <= score <= 1 for score in observation["scores"].values())
        assert abs(sum(observation["scores"].values()) - 1) < 1e-9
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            play(binary, variant, teacher)
