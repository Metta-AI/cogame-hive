"""Join schema-2 player captures to complete, verified native Hive replays."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
from typing import Literal
import zipfile

from pydantic import BaseModel, ConfigDict

from prompts import PromptSelection


class Message(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class Generation(BaseModel):
    request_body: str
    response_body: str
    response_status: int
    model: str


class Decision(BaseModel):
    decision_id: int
    tick: int
    source: Literal["scripted", "llm", "trained"]
    prompt_template: dict
    executed_action: dict
    accepted: bool
    receipt: dict
    transmissions: int
    generation: Generation
    prompt: list[Message]
    completion: list[Message]


class Trajectory(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schema_version: Literal[2]
    game: Literal["hive"]
    slot: int
    backend: Literal["scripted", "llm", "trained"]
    source_revision: str
    complete: Literal[True]
    reason: Literal["complete"]
    scores: list[float]
    decisions: list[Decision]


def write_private(path: Path, content: str) -> None:
    with os.fdopen(
        os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w"
    ) as output:
        output.write(content)


def export(runs: list[Path], output: Path, revision: str, verifier: Path) -> None:
    if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
        raise ValueError("source revision must be a full commit")
    seeds = {json.loads((run / "config.json").read_text())["seed"] for run in runs}
    if len(seeds) < 10:
        raise ValueError("at least ten complete seed families are required")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    write_private(output / "trajectories.jsonl", "")
    episodes: set[str] = set()
    for run in runs:
        config = json.loads((run / "config.json").read_text())
        results = json.loads((run / "results.json").read_text())
        replay = json.loads((run / "replay.json").read_text())
        events = [
            json.loads(line)
            for line in (run / "private/host.jsonl").read_text().splitlines()
        ]
        started, completed = events[0], events[-1]
        if (
            started["event_type"] != "host_started"
            or started["source_revision"] != revision
            or started["source_dirty"]
            or started["config"] != config
            or completed["event_type"] != "host_completed"
            or completed["result"] != results
            or results["reason"] != "complete"
            or replay["results"] != results
            or replay["seed"] != config["seed"]
        ):
            raise ValueError("incomplete or unqualified host capture")
        selection = PromptSelection.model_validate(started["prompt_selection"])
        if selection.variant.startswith("heldout-"):
            raise ValueError("held-out wording is evaluation only")
        applied = [
            event["doctrine"]
            for event in events
            if event["event_type"] == "action_applied"
        ]
        if applied != replay["doctrines"] or not applied:
            raise ValueError("host application log differs from replay")
        subprocess.run([verifier, run / "replay.json"], check=True)
        installed = {(entry["turn"], entry["seat"]): entry for entry in applied}
        if len(installed) != len(applied):
            raise ValueError("duplicate applied decision")
        family = f"hive-{config['seed']}"
        # Include mechanics and wording replicas while retaining one seed family.
        episode = f"{family}-ticks-{replay['tick_count']}-{selection.variant}-{selection.seed}"
        if episode in episodes:
            raise ValueError("duplicate episode")
        episodes.add(episode)
        captured: set[tuple[int, int]] = set()
        records: list[dict] = []
        for seat in range(4):
            with zipfile.ZipFile(run / f"policy_artifact_{seat}.zip") as archive:
                trajectory = Trajectory.model_validate_json(
                    archive.read("trajectory.json")
                )
            if (
                trajectory.slot != seat
                or trajectory.source_revision != revision
                or trajectory.scores != results["scores"]
            ):
                raise ValueError("player artifact identity or outcome mismatch")
            for index, decision in enumerate(trajectory.decisions):
                key = (decision.tick, seat)
                if decision.decision_id != index or key in captured:
                    raise ValueError("duplicate or noncontiguous player decisions")
                captured.add(key)
                actual = {
                    key: value
                    for key, value in installed[key].items()
                    if key not in ("turn", "seat", "source", "latency_ms")
                }
                if (
                    decision.executed_action != actual
                    or decision.receipt["action"] != actual
                    or decision.receipt["accepted"] != decision.accepted
                    or decision.receipt["turn"] != decision.tick
                ):
                    raise ValueError("receipt does not match the installed doctrine")
                if [message.role for message in decision.prompt] != [
                    "system",
                    "user",
                ] or [message.role for message in decision.completion] != ["assistant"]:
                    raise ValueError("unexpected prompt or completion shape")
                system, user = (message.content for message in decision.prompt)
                if (
                    system != selection.system_prompt()
                    or decision.prompt_template != selection.metadata(system, user)
                ):
                    raise ValueError("prompt wording or hashes differ")
                response = decision.completion[0].content
                if decision.source == "llm":
                    request = json.loads(decision.generation.request_body)
                    raw_response = json.loads(decision.generation.response_body)
                    if (
                        request["system"] != system
                        or request["model"] != decision.generation.model
                        or request["messages"] != [{"role": "user", "content": user}]
                        or raw_response["content"][0]["text"] != response
                        or not 200 <= decision.generation.response_status < 300
                    ):
                        raise ValueError(
                            "transport evidence differs from the candidate"
                        )
                identity = str(len(records))
                attempt_id = identity + "-player"
                messages = [message.model_dump() for message in decision.prompt]
                records.append(
                    {
                        "schema_version": "1",
                        "event_type": "decision",
                        "episode_id": episode,
                        "decision_id": identity,
                        "decision_index": len(records),
                        "game": "hive",
                        "game_version": "source-" + revision,
                        "source_revision": revision,
                        "seat": str(seat),
                        "visibility": "private",
                        "observation": {
                            "prompt_template": decision.prompt_template,
                            "applied_doctrine": installed[key],
                            "receipt": decision.receipt,
                            "transmissions": decision.transmissions,
                            "generation": decision.generation.model_dump(),
                        },
                        "prompt": messages,
                        "attempts": [
                            {
                                "attempt_id": attempt_id,
                                "policy": trajectory.backend,
                                "origin": "teacher"
                                if decision.source == "scripted"
                                else "unknown",
                                "inference_mode": "text_action",
                                "prompt": messages,
                                "response": response,
                                "parsed_action": actual if decision.accepted else None,
                                "accepted": decision.accepted,
                                "rejection_reason": None
                                if decision.accepted
                                else "host_rejected",
                                "request": None,
                                "platform_call_id": None,
                                "behavior_logprobs": None,
                            }
                        ],
                        "selected_attempt_id": attempt_id
                        if decision.accepted
                        else None,
                        "executed_action": actual,
                        "action_status": "accepted"
                        if decision.accepted
                        else "fallback",
                        "fallback_origin": None if decision.accepted else "scripted",
                        "terminal": False,
                    }
                )
        if captured != set(installed):
            raise ValueError("player artifacts do not cover every applied decision")
        records.sort(
            key=lambda row: (
                row["observation"]["applied_doctrine"]["turn"],
                int(row["seat"]),
            )
        )
        for index, record in enumerate(records):
            record["decision_index"] = index
        records[-1]["terminal"] = True
        records.append(
            {
                "schema_version": "1",
                "event_type": "episode",
                "episode_id": episode,
                "seed_family": family,
                "game": "hive",
                "game_version": "source-" + revision,
                "source_revision": revision,
                "status": "completed",
                "outcome": results,
                "participant_outcomes": {
                    str(seat): {"score": results["scores"][seat]} for seat in range(4)
                },
            }
        )
        with (output / "trajectories.jsonl").open("a") as stream:
            for record in records:
                stream.write(json.dumps(record) + "\n")
        write_private(output / (episode + ".replay.json"), json.dumps(replay))
    write_private(
        output / "manifest.json",
        json.dumps(
            {
                "schema_version": "1",
                "format": "coworld-private-candidates-v1",
                "review_required": True,
                "game": "hive",
                "source_revision": revision,
                "episodes": sorted(episodes),
                "seed_families": len(seeds),
            },
            indent=2,
        )
        + "\n",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--replay-verifier", required=True, type=Path)
    args = parser.parse_args()
    export(args.runs, args.output, args.source_revision, args.replay_verifier)
