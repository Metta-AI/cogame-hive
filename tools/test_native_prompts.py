"""Complete published games through both player protocols and real HTTP transport."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "players" / "ordinary"))
from prompts import PromptSelection  # noqa: E402


class FixtureServer(ThreadingHTTPServer):
    mode: str
    requests: list[dict]
    seen: set[tuple[int, int]]


class ReplyHandler(BaseHTTPRequestHandler):
    server: FixtureServer

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        user = request["messages"][0]["content"]
        view, _ = json.JSONDecoder().raw_decode(user.split("\n\n", 1)[1])
        seat = int(self.headers.get("X-Coworld-Player-Slot", "-1"))
        key = (seat, view["turn"])
        action = {
            "scouts": 999,
            "trail_gain": 4,
            "poach": 2,
            "spread": 2,
            "lay_food": 4,
            "lay_home": 4,
            "focus_weight": 4,
            "recall": 0,
            "focus": [3, 3],
            "note": "fixture",
            "say": "fixture",
        }
        text = json.dumps(action)
        if self.server.mode == "hosted" and key not in self.server.seen:
            text = "invalid fixture reply"
        if self.server.mode == "rejected":
            text = json.dumps({"scouts": "invalid"})
        self.server.seen.add(key)
        response = json.dumps(
            {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
        ).encode()
        self.server.requests.append(
            {"body": body.decode(), "response": response.decode()}
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format: str, *args) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("replay_verifier", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [
        (variant, "canonical", mode)
        for variant in variants
        for mode in ("hosted", "ordinary")
    ]
    if not args.smoke:
        cases += [
            ("sprint", wording, mode)
            for mode in ("hosted", "ordinary")
            for wording in (
                "plain",
                "numbered",
                "questions",
                "reordered",
                "heldout-briefing",
                "heldout-reference",
                "mixed",
            )
        ]
        cases.append(("sprint", "canonical", "rejected"))
    for variant, wording, mode in cases:
        output = args.output / f"{variant}-{wording}-{mode}"
        output.mkdir(mode=0o700)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        httpd = FixtureServer(("127.0.0.1", 0), ReplyHandler)
        httpd.mode, httpd.requests, httpd.seen = mode, [], set()
        thread = Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        config = {
            **variants[variant],
            "seed": 7,
            "promptVariant": wording,
            "promptSeed": 3,
            "tokens": [f"t{i}" for i in range(4)],
            "players": [{"name": f"private-player-{i}"} for i in range(4)],
        }
        (output / "config.json").write_text(json.dumps(config))
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "HIVE_CAPTURE_DIR": str(output / "private"),
            "HIVE_CAPTURE_TRAINING": "1",
            "HIVE_SOURCE_REVISION": revision,
            "PLAYER_PROMPT": "Choose a foraging doctrine.",
            "PLAYER_SCRIPTED": "",
            "COWORLD_LLM_MODEL": "fixture/validation",
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{httpd.server_port}",
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([args.game], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(400):
                assert processes[0].poll() is None, (output / "game.log").read_text()
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game did not start")
            for seat in range(4):
                log = (output / f"player-{seat}.log").open("w")
                logs.append(log)
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": (
                        output / f"policy_artifact_{seat}.zip"
                    ).as_uri(),
                }
                command = (
                    [str(args.player)]
                    if mode == "hosted"
                    else [sys.executable, "players/ordinary/player.py"]
                )
                processes.append(
                    subprocess.Popen(
                        command, cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=800) == 0, output
            results = json.loads((output / "results.json").read_text())
            assert results["reason"] == "complete"
            events = [
                json.loads(line)
                for line in (output / "private/host.jsonl").read_text().splitlines()
            ]
            assert (
                events[0]["source_revision"] == revision
                and not events[0]["source_dirty"]
            )
            assert events[-1]["event_type"] == "host_completed"
            assert (output / "private/host.jsonl").stat().st_mode & 0o777 == 0o600
            replay = json.loads((output / "replay.json").read_text())
            applied = [
                event["doctrine"]
                for event in events
                if event["event_type"] == "action_applied"
            ]
            assert applied == replay["doctrines"] and applied
            decisions = {
                (event["turn"], event["seat"]): event
                for event in events
                if event["event_type"] == "decision_resolved"
            }
            selection = PromptSelection.model_validate(events[0]["prompt_selection"])
            system = selection.system_prompt()
            for installed in applied:
                resolved = decisions[(installed["turn"], installed["seat"])]
                action = {
                    key: value
                    for key, value in installed.items()
                    if key not in ("turn", "seat", "source", "latency_ms")
                }
                assert action == resolved["resolved_action"]
                if mode == "hosted":
                    first, second = resolved["attempts"]
                    assert not first["accepted"] and second["accepted"]
                    assert second["parsed_action"] == action
                    for attempt in (first, second):
                        request = json.loads(attempt["request_body"])
                        assert request["system"] == system
                        assert attempt["prompt_template"] == selection.metadata(
                            system, request["messages"][0]["content"]
                        )
                        assert {
                            "body": attempt["request_body"],
                            "response": attempt["response_body"],
                        } in httpd.requests
            if mode != "hosted":
                for seat in range(4):
                    with zipfile.ZipFile(
                        output / f"policy_artifact_{seat}.zip"
                    ) as archive:
                        trajectory = json.loads(archive.read("trajectory.json"))
                    assert (
                        trajectory["schema_version"] == 2
                        and trajectory["scores"] == results["scores"]
                    )
                    rows = trajectory["decisions"]
                    assert len(rows) * 4 == len(applied)
                    for row in rows:
                        resolved = decisions[(row["tick"], seat)]
                        assert row["executed_action"] == resolved["resolved_action"]
                        assert row["accepted"] is (mode != "rejected")
                        assert row["transmissions"] == (2 if mode == "rejected" else 1)
                        assert row["prompt"][0]["content"] == system
                        assert row["prompt_template"] == selection.metadata(
                            system, row["prompt"][1]["content"]
                        )
                        generation = row["generation"]
                        assert {
                            "body": generation["request_body"],
                            "response": generation["response_body"],
                        } in httpd.requests
                        assert (
                            row["completion"][0]["content"]
                            == json.loads(generation["response_body"])["content"][0][
                                "text"
                            ]
                        )
            subprocess.run(
                [args.replay_verifier, output / "replay.json"], cwd=ROOT, check=True
            )
            print(
                variant,
                wording,
                mode,
                len(applied),
                "applied actions and replay PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
            httpd.shutdown()
            httpd.server_close()
            thread.join()


if __name__ == "__main__":
    main()
