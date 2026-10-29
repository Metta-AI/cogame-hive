"""Real Hive HTTP/four-player WS system proof; local fixture IDs are never teachers."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

from websockets.exceptions import ConnectionClosed, InvalidHandshake
from websockets.sync.client import connect


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--player", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--capture", action="store_true")
    parser.add_argument(
        "--operator-prompt",
        default="native fixture only",
        help="Frozen operator for all four local fixture seats",
    )
    parser.add_argument("--expect-missing", action="store_true")
    parser.add_argument(
        "--mode",
        choices=["normal", "mixed", "unicode-red", "boundary"],
        default="normal",
    )
    parser.add_argument(
        "--sink-failure",
        action="store_true",
        help="Private file URI points to a directory; public artifacts must survive",
    )
    parser.add_argument(
        "--forensic-metadata",
        action="store_true",
        help="Valid native action with an invalid Unicode provider model diagnostic",
    )
    parser.add_argument("--ownership-case", choices=["race", "persistence"])
    parser.add_argument("--race-pairs", type=int, default=0)
    args = parser.parse_args()
    assert 0 <= args.race_pairs <= 5
    assert args.ownership_case == "race" or args.race_pairs == 0
    assert args.ownership_case != "race" or args.race_pairs > 0
    allowed = {"PATH", "HOME", "TMPDIR", "LANG", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}
    assert not set(os.environ) - allowed, "Use env -i for the parent too"
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    begin = time.monotonic()
    done = threading.Event()
    children, logs, calls, ws_rows = [], [], [], []
    lock = threading.Lock()
    base = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    ticks = (
        240 if args.mode == "unicode-red" else 480 if args.mode == "boundary" else 4800
    )
    config: dict[str, Any] = {
        "seed": 1988503998,
        "num_agents": 4,
        "antsPerColony": 24,
        "episodeTicks": ticks,
        "turnTicks": 240,
        "turnBudgetSeconds": 22,
        "wallClockBudgetSeconds": 660,
        "playerConnectTimeoutSeconds": 90,
        "bonanzaTicks": [1200, 3600],
        "fieldPath": "meadow",
        "players": [{"name": f"fixture-{i}"} for i in range(4)],
        "tokens": [f"fixture-token-{i}" for i in range(4)],
    }
    if args.ownership_case:
        config.update(
            episodeTicks=960,
            turnBudgetSeconds=2,
            wallClockBudgetSeconds=60,
            playerConnectTimeoutSeconds=15,
            episodeTimeoutSeconds=120,
            bonanzaTicks=[],
        )
    (output / "config.json").write_text(json.dumps(config))
    (output / "operators.json").write_text(
        json.dumps(
            [args.operator_prompt, "", "", ""]
            if args.ownership_case
            else [args.operator_prompt] * 4
        )
    )

    def save_calls():
        with lock:
            (output / "http.json").write_text(json.dumps(calls, indent=2))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            row = {
                "arrival_s": time.monotonic() - begin,
                "request_b64": base64.b64encode(raw).decode(),
                "headers": dict(self.headers),
                "path": self.path,
            }
            calls.append(row)
            save_calls()  # Original bytes survive every later assertion or send failure.
            try:
                if args.ownership_case == "persistence":
                    time.sleep(0.1)
                request = json.loads(raw)
                slot = int(self.headers["X-Coworld-Player-Slot"])
                assert request["max_tokens"] == 900 and request["temperature"] == 0.4
                assert request["model"] == "local-hive-sentinel"
                view = json.loads(
                    request["messages"][0]["content"]
                    .split("\n\nYour previous reply")[0]
                    .rsplit("\n\n", 1)[1]
                )
                turn = view["turn"]
                retry = (
                    "Your previous reply was invalid"
                    in request["messages"][0]["content"]
                )
                previous = sum(
                    c.get("slot") == slot and c.get("turn") == turn for c in calls
                )
                action = {
                    "scouts": 55,
                    "trail_gain": 25,
                    "poach": 10,
                    "spread": 55,
                    "lay_food": 70,
                    "lay_home": 55,
                    "recall": False,
                    "focus": None,
                    "focus_weight": 0,
                    "note": f"private-note-seat-{slot}",
                    "say": "",
                }
                text = json.dumps(action, separators=(",", ":"))
                status = 200
                case = "normal"
                if args.mode == "boundary" and turn == 0:
                    text = "not JSON"  # Exhaust both native attempts on hosted seats.
                elif args.mode == "unicode-red":
                    action["note"] = "\udc00"
                    text = json.dumps(action)
                    case = "lone-low-consumed-note"
                elif args.mode == "mixed" and slot == 0:
                    case = str(turn)
                    if turn == 0:
                        text = "```json\n" + text + "\n```"
                    elif turn == 1:
                        text = text.replace('"scouts":55', '"scouts":"55"')
                    elif turn == 2:
                        text = text[:-1] + ',"scouts":55}'
                    elif turn in (3, 4):
                        text = text.replace('"recall":false', '"recall":true')
                    elif turn == 5 and not retry:
                        text = "not JSON"
                    elif turn == 6 and previous == 0:
                        status = 429
                    elif turn == 7 and not retry:
                        action["note"] = "\udc00"
                        text = json.dumps(action)
                    elif turn == 8:
                        text = text[:-1] + ',"ignored":1e999}'
                    elif turn == 9:
                        text = text.replace('"scouts":55', '"scouts":155')
                    elif turn == 10:
                        text = text.replace(
                            '"note":"private-note-seat-0"', '"note":"é 😀"'
                        )
                body = json.dumps(
                    {
                        "id": "local-only",
                        "model": "\udc00"
                        if args.forensic_metadata and slot == 1 and turn == 1
                        else "local-hive-sentinel",
                        "stop_reason": "end_turn",
                        "content": [{"type": "text", "text": text}],
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    }
                ).encode()
                call = str(uuid.uuid4())
                row.update(
                    slot=slot,
                    turn=turn,
                    case=case,
                    status=status,
                    text=text,
                    call_id=call,
                    response_b64=base64.b64encode(body).decode(),
                )
                save_calls()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Softmax-Llm-Call-Id", call)
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                row["send_success_s"] = time.monotonic() - begin
            except BaseException as exc:
                row["error"] = type(exc).__name__
                raise
            finally:
                save_calls()

        def log_message(self, format: str, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    def launch(argv, env, name):
        assert not any(
            any(
                x in key
                for x in ("ANTHROPIC", "BEDROCK", "AWS_", "OPENAI", "OPENROUTER")
            )
            for key in env
        )
        with (output / "environment-audit.jsonl").open("a") as f:
            f.write(json.dumps({"argv": argv, "env_keys": sorted(env)}) + "\n")
        stream = (output / (name + ".log")).open("wb")
        logs.append(stream)
        child = subprocess.Popen(argv, env=env, stdout=stream, stderr=subprocess.STDOUT)
        children.append(child)
        return child

    def monitor():
        with (output / "metrics.jsonl").open("w") as stream:
            while not done.is_set():
                row = {
                    "elapsed_s": time.monotonic() - begin,
                    "free_bytes": shutil.disk_usage(output).free,
                    "bytes": sum(
                        f.stat().st_size for f in output.rglob("*") if f.is_file()
                    ),
                    "http_calls": len(calls),
                    "processes": [],
                }
                for child in children:
                    ps = subprocess.run(
                        ["ps", "-p", str(child.pid), "-o", "pid=,pcpu=,rss=,etime="],
                        capture_output=True,
                        text=True,
                        env=base,
                        timeout=2,
                        check=False,
                    )
                    row["processes"].append(
                        {
                            "pid": child.pid,
                            "returncode": child.poll(),
                            "ps": ps.stdout.strip() or None,
                        }
                    )
                stream.write(json.dumps(row) + "\n")
                stream.flush()
                if (
                    row["elapsed_s"] > 180
                    or row["bytes"] > 16 * 1024**2
                    or row["free_bytes"] < 2 * 1024**3
                    or len(calls) > 180
                ):
                    for child in children:
                        if child.poll() is None:
                            child.terminate()
                    return
                done.wait(0.5)

    threading.Thread(target=monitor, daemon=True).start()

    def viewer():
        try:
            with connect(f"ws://127.0.0.1:{port}/global", open_timeout=5) as ws:
                while not done.is_set():
                    try:
                        msg = ws.recv(timeout=0.2)
                        raw = msg.encode() if isinstance(msg, str) else msg
                        ws_rows.append(
                            {
                                "body_b64": base64.b64encode(raw).decode(),
                                "elapsed_s": time.monotonic() - begin,
                            }
                        )
                    except TimeoutError:
                        ws.ping().wait(2)
                        ws_rows.append({"pong": True})
        except (OSError, TimeoutError, ConnectionClosed) as exc:
            ws_rows.append({"end": type(exc).__name__})
        finally:
            (output / "global-ws.json").write_text(json.dumps(ws_rows))

    try:
        env = base | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
            "COWORLD_LLM_MODEL": "local-hive-sentinel",
            "COWORLD_GAME_NAME": "hive",
            "COWORLD_EPISODE_ID": "local-hive-native",
            "COWORLD_GAME_VERSION": "0.0.0",
            "COWORLD_SOURCE_REVISION": "workingtree-sha256:"
            + hashlib.sha256(
                b"".join(p.read_bytes() for p in sorted(Path("src").rglob("*.nim")))
            ).hexdigest(),
            "COWORLD_GAME_IMAGE_DIGEST": "sha256:" + "0" * 64,
        }
        if args.capture or args.expect_missing:
            env["COGAME_SAVE_TRAJECTORY_URI"] = (
                output if args.sink_failure else output / "trajectory.jsonl"
            ).as_uri()
        game = launch([str(args.game.resolve())], env, "game")
        deadline = time.monotonic() + 15
        while True:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ) as response:
                    assert response.status == 200
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.05)
        watcher = threading.Thread(target=viewer, daemon=True)
        watcher.start()
        external_rows = []

        def external():
            try:
                with connect(
                    f"ws://127.0.0.1:{port}/player?slot=0&token={config['tokens'][0]}",
                    open_timeout=5,
                ) as ws:
                    register = {
                        "type": "register",
                        "scripted": None,
                        "policy": "local-external",
                    }
                    ws.send(json.dumps(register))
                    while True:
                        raw = ws.recv(timeout=30)
                        external_rows.append({"received": raw})
                        packet = json.loads(raw)
                        if packet.get("done"):
                            break
                        if packet.get("type") == "welcome":
                            ws.send(json.dumps(register))
                        if packet.get("type") != "decision_request":
                            continue
                        action = {"note": "é 😀", "say": "KEEP"}
                        if packet["turn"] == 0 and not packet.get("retry"):
                            action["note"] = "\udc00"
                        reply = json.dumps(
                            {
                                "type": "decision",
                                "turn": packet["turn"],
                                "action": action,
                                "source": "external",
                            }
                        )
                        external_rows.append({"sent": reply})
                        ws.send(reply)
            except Exception as error:
                external_rows.append({"error": type(error).__name__})
                raise
            finally:
                (output / "external-ws.json").write_text(json.dumps(external_rows))

        external_thread = None
        ownership_rows = []
        if args.ownership_case:

            def open_seat(seat):
                return connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={config['tokens'][seat]}",
                    open_timeout=2,
                    close_timeout=1,
                    legacy=True,
                )

            winner = None
            race_rows: list[dict[str, Any]] = []
            if args.ownership_case == "race":

                def contender():
                    try:
                        ws = open_seat(0)
                        try:
                            welcome = json.loads(ws.recv(timeout=0.3))
                            return ws, welcome.get("type") == "welcome"
                        except (TimeoutError, ConnectionClosed):
                            return ws, False
                    except InvalidHandshake as error:
                        cause, messages = error, []
                        while cause is not None:
                            messages.append(str(cause))
                            cause = cause.__cause__
                        assert any("409" in text for text in messages), messages
                        return None, False

                for pair in range(args.race_pairs):
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        both = list(pool.map(lambda _: contender(), range(2)))
                    race_rows.append({"pair": pair, "welcomed": [w for _, w in both]})
                    (output / "race.json").write_text(json.dumps(race_rows, indent=2))
                    for ws, welcomed in both:
                        if ws is not None:
                            if (
                                pair == args.race_pairs - 1
                                and welcomed
                                and winner is None
                            ):
                                winner = ws
                            else:
                                ws.close()
                    time.sleep(0.03)
            if winner is None:
                winner = open_seat(0)

            def ownership_player(seat):
                ws = winner if seat == 0 else open_seat(seat)
                register = {
                    "type": "register",
                    "scripted": "marcher",
                    "policy": "ownership-scripted",
                    "prompt": "",
                }
                if seat == 0:
                    register = (
                        {
                            "type": "register",
                            "scripted": None,
                            "policy": "ownership-external",
                        }
                        if args.ownership_case == "race"
                        else {
                            "type": "register",
                            "scripted": None,
                            "policy": "ownership-persistent",
                            "prompt": args.operator_prompt,
                        }
                    )

                def send(value):
                    ws.send(json.dumps(value))
                    with lock:
                        ownership_rows.append(
                            {
                                "seat": seat,
                                "sent": value,
                                "elapsed_s": time.monotonic() - begin,
                            }
                        )

                with ws:
                    send(register)
                    while True:
                        packet = json.loads(ws.recv(timeout=25))
                        with lock:
                            ownership_rows.append(
                                {
                                    "seat": seat,
                                    "received": packet,
                                    "elapsed_s": time.monotonic() - begin,
                                }
                            )
                        if packet.get("type") == "welcome":
                            send(register)
                        if packet.get("done"):
                            return
                        if seat == 0 and packet.get("type") == "decision_request":
                            send(
                                {
                                    "type": "decision",
                                    "turn": packet["turn"],
                                    "source": "external",
                                    "action": {
                                        "scouts": 40,
                                        "note": "ownership-external",
                                        "say": "",
                                    },
                                }
                            )
                        if (
                            seat == 0
                            and args.ownership_case == "persistence"
                            and packet.get("type") == "turn"
                        ):
                            with lock:
                                ownership_rows.append(
                                    {
                                        "seat": 0,
                                        "close_started_s": time.monotonic() - begin,
                                    }
                                )
                            ws.close()
                            with lock:
                                ownership_rows.append(
                                    {
                                        "seat": 0,
                                        "close_completed_s": time.monotonic() - begin,
                                    }
                                )
                            return

            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(ownership_player, range(4)))
            (output / "ownership-ws.json").write_text(
                json.dumps(ownership_rows, indent=2)
            )
        else:
            external_thread = None
            if args.mode == "boundary":
                external_thread = threading.Thread(target=external, daemon=True)
                external_thread.start()
            for slot in range(1 if args.mode == "boundary" else 0, 4):
                launch(
                    [str(args.player.resolve())],
                    base
                    | {
                        "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token={config['tokens'][slot]}",
                        "PLAYER_PROMPT": args.operator_prompt,
                    },
                    f"player-{slot}",
                )
        game.wait(timeout=max(1, 180 - (time.monotonic() - begin)))
        assert game.returncode == 0
        for child in children[1:]:
            child.wait(timeout=5)
            assert child.returncode == 0
        if external_thread:
            external_thread.join(timeout=5)
            assert not external_thread.is_alive() and not any(
                "error" in row for row in external_rows
            )
        raw = (output / "replay.json").read_bytes()
        if args.ownership_case:
            replay = json.loads(raw)
            assert (
                replay["tick_count"] == 960
                and replay["results"]["reason"] == "complete"
            )
            assert len(replay["doctrines"]) == 16
            if args.ownership_case == "race":
                assert len(calls) == 0
                requests = [
                    row
                    for row in ownership_rows
                    if row.get("seat") == 0
                    and row.get("received", {}).get("type") == "decision_request"
                ]
                assert len(requests) == 4, (
                    "winner lost external control after competitor close"
                )
                assert all(sum(row["welcomed"]) <= 1 for row in race_rows), (
                    "duplicate welcomed owners"
                )
            else:
                assert len(calls) == 4 and all(row["slot"] == 0 for row in calls)
                closed = next(
                    row["close_completed_s"]
                    for row in ownership_rows
                    if "close_completed_s" in row
                )
                later = [row for row in calls if row["arrival_s"] > closed]
                assert later and max(row["turn"] for row in later) == 3
                assert all(
                    args.operator_prompt
                    in json.loads(base64.b64decode(row["request_b64"]))["messages"][0][
                        "content"
                    ]
                    for row in later
                )
            result = {
                "status": "PASS",
                "ownership_case": args.ownership_case,
                "component_ticks": 960,
                "ordinary_complete": False,
                "http_calls": len(calls),
                "genuine_teachers": 0,
            }
        elif args.mode == "unicode-red":
            invalid = False
            try:
                raw.decode("utf8")
            except UnicodeDecodeError:
                invalid = True
            assert invalid, "original scalar poisoning control did not reproduce"
            result = {
                "status": "EXPECTED_NATIVE_INVALID_UTF8",
                "ordinary_complete": False,
                "partial_ticks": 240,
                "http_calls": len(calls),
                "raw_sha256": hashlib.sha256(raw).hexdigest(),
            }
        elif args.mode == "boundary":
            replay = json.loads(raw)
            assert (
                replay["tick_count"] == 480
                and replay["results"]["reason"] == "complete"
            )
            assert len(calls) == 9 and len(replay["doctrines"]) == 8
            assert replay["doctrines"][0]["note"] == "é 😀"
            assert all(row["source"] == "fallback" for row in replay["doctrines"][1:4])
            assert len([row for row in external_rows if "sent" in row]) == 3
            if args.sink_failure:
                assert not (output / "trajectory.jsonl").exists()
                assert (
                    "private capture publication failed"
                    in (output / "game.log").read_text()
                )
            else:
                rows = [
                    json.loads(x)
                    for x in (output / "trajectory.jsonl").read_text().splitlines()
                ]
                assert sum(row.get("action_status") == "fallback" for row in rows) == 3
                assert all(
                    row.get("selected_attempt_id") is None
                    for row in rows
                    if row.get("action_status") == "fallback"
                )
            if args.forensic_metadata:
                target = next(
                    row for row in rows if row.get("decision_id") == "turn-1-seat-1"
                )
                assert (
                    target["selected_attempt_id"] is None
                    and target["executed_action"] is None
                    and target["attempts"] == []
                )
                original = base64.b64decode(
                    target["observation"]["invalid_native_evidence_json_b64"]
                )
                assert b"\xed\xb0\x80" in original and rows[-1]["status"] == "failed"
            result = {
                "status": "PASS",
                "component_ticks": 480,
                "ordinary_complete": False,
                "http_calls": len(calls),
                "external_invalid_consumed_text_retry": True,
                "native_exhausted_fallbacks": 3,
                "private_sink_failure": args.sink_failure,
                "genuine_teachers": 0,
            }
        else:
            replay = json.loads(raw)
            assert (
                replay["tick_count"] == 4800
                and replay["results"]["reason"] == "complete"
            )
            assert len(replay["doctrines"]) == 80 and len(calls) >= 80
            assert all("send_success_s" in c and "error" not in c for c in calls)
            assert any(x.get("pong") for x in ws_rows) and any(
                "body_b64" in x for x in ws_rows
            )
            if args.expect_missing:
                assert not (output / "trajectory.jsonl").exists()
            elif args.capture:
                assert (output / "trajectory.jsonl").exists()
            result = {
                "status": "EXPECTED_MISSING_TRAJECTORY"
                if args.expect_missing
                else "PASS",
                "ticks": 4800,
                "turns": 20,
                "http_calls": len(calls),
                "genuine_teachers": 0,
                "fixture_UUIDs_not_receipts": True,
            }
        (output / "result-card.json").write_text(json.dumps(result, indent=2) + "\n")
    finally:
        if args.ownership_case:
            (output / "ownership-ws.json").write_text(
                json.dumps(ownership_rows, indent=2)
            )
        done.set()
        server.shutdown()
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for stream in logs:
            stream.close()
        save_calls()
        (output / "global-ws.json").write_text(json.dumps(ws_rows))


if __name__ == "__main__":
    main()
