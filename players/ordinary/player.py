"""Hive doctrines through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import math
import os
import time
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture
from policy import ScriptedPolicy, prompt_for


def choose(turn: dict, generator, marcher: ScriptedPolicy, driftling: ScriptedPolicy,
           strategy: str, scripted: str) -> tuple[dict, str, str, str]:
    view = turn["view"]
    candidates = [marcher.decide(view), driftling.decide(view)]
    system, user = prompt_for(view, strategy)
    if scripted:
        return candidates[1 if scripted == "driftling" else 0], "scripted", system, user
    if generator:
        completion = generator(
            [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ]
        )
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Hive decision must be a JSON object")
        return action, "trained", system, user
    if os.environ.get("HIVE_JEV") != "1":
        if strategy:
            body = json.dumps({"model": os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5"),
                               "max_tokens": 500, "system": system,
                               "messages": [{"role": "user", "content": user}]}).encode()
            request = urllib.request.Request(
                "https://api.anthropic.com/v1/messages", body,
                {"Content-Type": "application/json", "anthropic-version": "2023-06-01",
                 "x-api-key": os.environ["ANTHROPIC_API_KEY"]}, method="POST")
            with urllib.request.urlopen(request, timeout=10) as response:
                action = json.loads(json.load(response)["content"][0]["text"])
            return action, "llm", system, user
        return candidates[0], "scripted", system, user
    sidecar = os.environ.get("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "").strip()
    capture = os.environ.get("METTA_CAPTURE_URL", "").strip()
    if sidecar:
        endpoint, model, key = sidecar, "typesafe/jev-1.13", ""
    elif capture:
        endpoint = capture
        model = os.environ.get("METTA_CAPTURE_MODEL", "jev-latest")
        key = os.environ["METTA_CAPTURE_KEY"]
    else:
        endpoint = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
        model = os.environ.get("TYPESAFE_DEFAULT_MODEL", "jev-latest")
        key = os.environ["TYPESAFE_API_KEY"]
    criteria = {
        str(index): json.dumps(candidate, sort_keys=True)
        for index, candidate in enumerate(candidates)
    }
    body = json.dumps(
        {
            "model": model,
            "state": {"policy": system, "summary": user},
            "questions": {
                "action": {
                    "type": "choice",
                    "instructions": "Choose one complete Hive doctrine.",
                    "criteria": criteria,
                }
            },
        }
    ).encode()
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/v1/systemone", body, headers, method="POST"
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        answer = json.load(response)["answers"]["action"]
    if answer["type"] != "choice" or len(answer["probabilities"]) != len(candidates):
        raise ValueError("Jev returned the wrong Hive decision catalog")
    probabilities = [answer["probabilities"][str(i)] for i in range(len(candidates))]
    if (
        any(
            not isinstance(p, (int, float)) or not math.isfinite(p) or p < 0 or p > 1
            for p in probabilities
        )
        or abs(sum(probabilities) - 1) > len(candidates) * 0.005 + 1e-6
    ):
        raise ValueError("Jev returned invalid Hive decision probabilities")
    return candidates[max(range(len(candidates)), key=probabilities.__getitem__)], "jev", system, user


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("HIVE_ADAPTER_DIR")
    if adapter and os.environ.get("HIVE_JEV") == "1":
        raise ValueError("select one Hive policy backend")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    strategy = os.environ.get("PLAYER_PROMPT", "")
    scripted = os.environ.get("PLAYER_SCRIPTED", "")
    backend = ("trained" if adapter else "jev" if os.environ.get("HIVE_JEV") == "1"
               else "llm" if strategy else "scripted")
    if backend == "scripted" and not scripted:
        scripted = "marcher"
    marcher = ScriptedPolicy()
    driftling = ScriptedPolicy("driftling")
    artifact = Capture(slot, backend) if os.environ.get("HIVE_CAPTURE_TRAINING") == "1" else None
    registration = json.dumps(
        {
            "type": "register",
            "scripted": scripted,
            "policy": os.environ.get("PLAYER_POLICY_LABEL", backend)[:128],
        }
    )
    deadline = time.monotonic() + 90
    while True:
        try:
            socket = websocket.create_connection(url, timeout=10)
            break
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.25)
    socket.settimeout(120)
    socket.send(registration)
    calls = 0
    pending: dict[int, tuple[str, str, dict, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Hive closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        if "done" in frame:
            if pending:
                raise RuntimeError("Hive ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["result"]["scores"], frame["result"]["reason"])
            break
        kind = frame["type"]
        if kind == "welcome":
            socket.send(registration)
        elif kind == "decision_request":
            if frame["turn"] not in pending:
                action, source, system, user = choose(
                    frame, generator, marcher, driftling, strategy, scripted)
                if source == "jev":
                    calls += 1
                pending[frame["turn"]] = (system, user, action, source)
            _, _, action, source = pending[frame["turn"]]
            socket.send(json.dumps({"type": "decision", "turn": frame["turn"],
                                    "action": action, "source": source}))
        elif kind == "decision_result":
            system, user, action, source = pending.pop(frame["turn"])
            if artifact and frame["accepted"]:
                artifact.record(system, user, action, source, frame["turn"])
    socket.close()
    print(f"Hive ordinary player finished: slot={slot} backend={backend} Jev calls={calls}", flush=True)


if __name__ == "__main__":
    main()
