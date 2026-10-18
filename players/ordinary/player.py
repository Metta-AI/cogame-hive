"""Hive doctrines through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
import time
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture, Choice
from policy import ScriptedPolicy, prompt_for
from prompts import PromptSelection


def choose(
    turn: dict,
    generator,
    marcher: ScriptedPolicy,
    driftling: ScriptedPolicy,
    strategy: str,
    scripted: str,
    selection: PromptSelection,
) -> Choice:
    view = turn["view"]
    candidates = [marcher.decide(view), driftling.decide(view)]
    system, user = prompt_for(view, strategy, selection)
    if scripted:
        action = candidates[1 if scripted == "driftling" else 0]
        return Choice(
            action=action,
            source="scripted",
            system=system,
            user=user,
            completion=json.dumps(action, sort_keys=True),
        )
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
        return Choice(
            action=action,
            source="trained",
            system=system,
            user=user,
            completion=completion,
        )
    if strategy:
        endpoint = os.environ.get("COWORLD_LLM_ENDPOINT", "").rstrip("/")
        model = (
            os.environ.get("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
            if endpoint
            else os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001")
        )
        body = json.dumps(
            {
                "model": model,
                "max_tokens": 500,
                "system": system,
                "messages": [{"role": "user", "content": user}],
            }
        ).encode()
        request = urllib.request.Request(
            (
                f"{endpoint}/v1/messages"
                if endpoint
                else "https://api.anthropic.com/v1/messages"
            ),
            body,
            {
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
                "x-api-key": (
                    "sidecar" if endpoint else os.environ["ANTHROPIC_API_KEY"]
                ),
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            response_body = response.read().decode()
            response_status = response.status
        completion = json.loads(response_body)["content"][0]["text"]
        return Choice(
            action=json.loads(completion),
            source="llm",
            system=system,
            user=user,
            completion=completion,
            request_body=body.decode(),
            response_body=response_body,
            response_status=response_status,
            model=model,
        )
    return Choice(
        action=candidates[0],
        source="scripted",
        system=system,
        user=user,
        completion=json.dumps(candidates[0], sort_keys=True),
    )


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("HIVE_ADAPTER_DIR")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    strategy = os.environ.get("PLAYER_PROMPT", "")
    scripted = os.environ.get("PLAYER_SCRIPTED", "")
    backend = "trained" if adapter else "llm" if strategy else "scripted"
    if backend == "scripted" and not scripted:
        scripted = "marcher"
    marcher = ScriptedPolicy()
    driftling = ScriptedPolicy("driftling")
    artifact = (
        Capture(slot, backend)
        if os.environ.get("HIVE_CAPTURE_TRAINING") == "1"
        else None
    )
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
    selection = PromptSelection()
    pending: dict[int, Choice] = {}
    transmissions: dict[int, int] = {}
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
            selection = PromptSelection.model_validate(frame["prompt_selection"])
            socket.send(registration)
        elif kind == "decision_request":
            if frame["turn"] not in pending:
                if (
                    PromptSelection.model_validate(frame["prompt_selection"])
                    != selection
                ):
                    raise ValueError("prompt selection changed during the episode")
                pending[frame["turn"]] = choose(
                    frame, generator, marcher, driftling, strategy, scripted, selection
                )
                transmissions[frame["turn"]] = 0
            choice = pending[frame["turn"]]
            transmissions[frame["turn"]] += 1
            socket.send(
                json.dumps(
                    {
                        "type": "decision",
                        "turn": frame["turn"],
                        "action": choice.action,
                        "source": choice.source,
                    }
                )
            )
        elif kind == "decision_result":
            choice = pending.pop(frame["turn"])
            sent = transmissions.pop(frame["turn"])
            if artifact:
                artifact.record(choice, frame, sent, selection)
    socket.close()
    print(f"Hive ordinary player finished: slot={slot} backend={backend}", flush=True)


if __name__ == "__main__":
    main()
