#!/usr/bin/env python3
"""Regenerate coworld_manifest_template.json.

The manifest inlines README.md, docs/RULES.md and docs/PROTOCOL.md as TEXT
(`game.docs`), and carries BOTH protocol documents as text (`game.protocols`),
because URI-form docs go missing on the coworld page. Keeping the manifest
generated from those files is what stops the three copies drifting.

The image placeholder is derived from the COMPOSE SERVICE NAME
(`service hive` -> `{{HIVE_IMAGE}}`): `{{GAME_IMAGE}}` is not a thing.

  usage: python3 scripts/gen_manifest.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEATS = 4


def compose_service() -> str:
    text = (ROOT / "compose.yaml").read_text()
    match = re.search(r"^services:\s*\n\s+([A-Za-z0-9_-]+):", text, re.M)
    if not match:
        raise SystemExit("no service in compose.yaml")
    return match.group(1)


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def players(n: int) -> list[dict]:
    return [{"name": f"P{i + 1}"} for i in range(n)]


def main() -> None:
    service = compose_service()
    image = "{{" + service.upper() + "_IMAGE}}"
    source_url = "https://github.com/Metta-AI/cogame-hive/tree/main"

    config_schema = {
        "tokens": {"type": "array", "items": {"type": "string"},
                   "description": "One auth token per seat."},
        "players": {"type": "array", "default": players(SEATS),
                    "description": "Per-seat player names."},
        "seed": {"type": "integer", "default": 0,
                 "description": "Episode seed. Unpinned means randomized."},
        "num_agents": {"type": "integer", "default": SEATS,
                       "description": "Colonies. Hive seats exactly four."},
        "antsPerColony": {"type": "integer", "default": 24},
        "episodeTicks": {"type": "integer", "default": 4800},
        "turnTicks": {"type": "integer", "default": 240},
        "antStepTicks": {"type": "integer", "default": 2},
        "cellPx": {"type": "integer", "default": 8},
        "pheromoneMax": {"type": "integer", "default": 4000},
        "pheromoneFloor": {"type": "integer", "default": 4},
        "pheromoneDecayNum": {"type": "integer", "default": 248},
        "decayPeriodTicks": {"type": "integer", "default": 8},
        "nestSenseCells": {"type": "integer", "default": 12},
        "maxOrbits": {"type": "integer", "default": 3},
        "sourceSpawnPeriod": {"type": "integer", "default": 240},
        "sourceAmount": {"type": "integer", "default": 60},
        "sourceLifeTicks": {"type": "integer", "default": 1440},
        "minNestClearance": {"type": "integer", "default": 14},
        "bonanzaTicks": {"type": "array", "items": {"type": "integer"},
                         "default": [1200, 3600]},
        "bonanzaAmount": {"type": "integer", "default": 100},
        "bonanzaLifeTicks": {"type": "integer", "default": 900},
        "raidRadius": {"type": "integer", "default": 20},
        "trailWarThreshold": {"type": "integer", "default": 800},
        "turnBudgetSeconds": {"type": "number", "default": 22},
        "wallClockBudgetSeconds": {"type": "number", "default": 660},
        "playerConnectTimeoutSeconds": {"type": "number", "default": 90},
        "fieldPath": {"type": "string", "default": "meadow"},
        "showPlayerLabels": {"type": "boolean", "default": True},
        "gameOverTicks": {"type": "integer", "default": 96},
    }

    per_seat_int = {"type": "array", "items": {"type": "integer"},
                    "minItems": SEATS, "maxItems": SEATS}
    per_seat_num = {"type": "array", "items": {"type": "number"},
                    "minItems": SEATS, "maxItems": SEATS}
    per_seat_str = {"type": "array", "items": {"type": "string"},
                    "minItems": SEATS, "maxItems": SEATS}
    per_seat_bool = {"type": "array", "items": {"type": "boolean"},
                     "minItems": SEATS, "maxItems": SEATS}

    results_schema = {
        "type": "object",
        "properties": {
            "names": per_seat_str,
            "aliases": per_seat_str,
            "colours": per_seat_str,
            "nests": {"type": "array", "minItems": SEATS, "maxItems": SEATS,
                      "items": {"type": "array",
                                "items": {"type": "integer"}}},
            "policy_kinds": per_seat_str,
            "scores": per_seat_num,
            "win": per_seat_bool,
            "delivered": per_seat_int,
            "harvested": per_seat_int,
            "raided_units": per_seat_int,
            "raided_from_you": per_seat_int,
            "peak_food_trail": per_seat_int,
            "ants": per_seat_int,
            "recalls": per_seat_int,
            "turns_llm": per_seat_int,
            "fallback_turns": per_seat_int,
            "fallback_causes": {
                "type": "array", "minItems": SEATS, "maxItems": SEATS,
                "items": {
                    "type": "object",
                    "properties": {
                        "timeout": {"type": "integer"},
                        "parse_error": {"type": "integer"},
                        "transport_error": {"type": "integer"},
                        "no_credentials": {"type": "integer"},
                        "budget_guard": {"type": "integer"},
                    },
                },
            },
            "total_delivered": {"type": "integer"},
            "sources_spawned": {"type": "integer"},
            "reason": {"type": "string",
                       "enum": ["complete", "deadline", "fault"]},
            "end_rule": {"type": "string",
                         "enum": ["full_time", "wall_clock", "sim_fault",
                                  "host_error"]},
            "winner": {"type": ["integer", "null"]},
            "final_tick": {"type": "integer"},
            "final_turn": {"type": "integer"},
            "seed": {"type": "integer"},
        },
        "required": [
            "names", "aliases", "colours", "nests", "policy_kinds", "scores",
            "win", "delivered", "harvested", "raided_units",
            "raided_from_you", "peak_food_trail", "ants", "recalls",
            "turns_llm", "fallback_turns", "fallback_causes",
            "total_delivered", "sources_spawned", "reason", "end_rule",
            "winner", "final_tick", "final_turn", "seed",
        ],
    }

    manifest = {
        "game": {
            "name": "hive",
            "owner": "daveey@softmax.com",
            "description": (
                "Four ant colonies foraging one meadow. Each seat is one "
                "policy driving twenty-four identical ants that see one cell "
                "around themselves, drop and smell two decaying pheromones, "
                "and carry food home. No messaging: coordination has to be "
                "stigmergic. Scored by your share of all food returned."
            ),
            "episode_timeout_minutes": 20,
            "runnable": {
                "image": image,
                "run": ["/bin/hive"],
                "source_url": source_url,
            },
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "config_schema": config_schema,
            "results_schema": results_schema,
            "protocols": {
                "player": {"type": "text", "value": read("docs/PROTOCOL.md")},
                "global": {
                    "type": "text",
                    "value": (
                        "# Hive - spectator channel (hive.global.v1)\n\n"
                        "`WS /global` streams one JSON snapshot per turn and "
                        "one on every connection:\n\n"
                        "```json\n"
                        "{\"type\": \"state\", \"game\": \"hive\", "
                        "\"protocol\": \"hive.global.v1\",\n"
                        " \"t\": 1680, \"turn\": 7, \"ticks\": 4800, "
                        "\"turns\": 20, \"fps\": 24,\n"
                        " \"speeds\": [1,2,3,4,8,16],\n"
                        " \"field\": {\"cols\": 160, \"rows\": 88, "
                        "\"cell_px\": 8, \"blocks\": [20,11],\n"
                        "           \"block_cells\": 8, \"rock\": [ ... 11 "
                        "rows of 20 chars ... ]},\n"
                        " \"colonies\": [{\"seat\": 0, \"nest\": 0, "
                        "\"alias\": \"Amber\", \"colour\": \"#f2c14e\",\n"
                        "               \"cell\": [16,12], \"player\": "
                        "\"daveey\", \"delivered\": 118,\n"
                        "               \"carrying\": 6, \"scouts\": 4, "
                        "\"doctrine\": { ... },\n"
                        "               \"doctrine_source\": \"llm\"}, ... 4 "
                        "... ],\n"
                        " \"ants\": [[cx, cy, state, colony], ... 96 ... ],\n"
                        " \"sources\": [{\"id\": 12, \"cell\": [76,43], "
                        "\"amount\": 41, \"spawn_amount\": 60}],\n"
                        " \"scoreboard\": [{\"colony\": \"Amber\", "
                        "\"delivered\": 118}, ... ],\n"
                        " \"started\": true, \"done\": false, "
                        "\"connected\": [true,true,true,true],\n"
                        " \"events\": [ ...the last 40 events... ]}\n"
                        "```\n\n"
                        "Ant state codes: 0 searching forager, 1 searching "
                        "scout, 2 carrying, 3 held by recall.\n\n"
                        "Real player names appear only in "
                        "`colonies[].player`, and only when "
                        "`showPlayerLabels` is set; every in-game surface "
                        "sees the colony alias.\n\n"
                        "`GET /client/global` is a real browser page over the "
                        "same feed. `GET /client/player` is the seat's "
                        "documentation page and deliberately never opens the "
                        "player websocket. `/healthz` and `/global` keep "
                        "answering for a 20 s shutdown grace after the "
                        "artifacts are written.\n\n"
                        "Replays are a STATIC wasm bundle, never a pod: the "
                        "viewer re-runs the same integer sim from the "
                        "recorded doctrine stream in the browser and verifies "
                        "its own re-derivation against the u32 digest in "
                        "every keyframe. It contacts nothing but the S3 URL "
                        "it was given.\n"
                    ),
                },
            },
            "docs": {
                "readme": {"type": "text", "value": read("README.md")},
                "pages": [
                    {
                        "id": "rules.md",
                        "title": "Rules",
                        "content": {"type": "text",
                                    "value": read("docs/RULES.md")},
                    },
                    {
                        "id": "protocol.md",
                        "title": "Wire protocol",
                        "content": {"type": "text",
                                    "value": read("docs/PROTOCOL.md")},
                    },
                ],
            },
            "player": [
                {
                    "id": "baseline",
                    "name": "marcher",
                    "type": "player",
                    "image": image,
                    "run": ["/bin/hive-player"],
                    "env": {"PLAYER_SCRIPTED": "marcher"},
                    "source_url": source_url,
                }
            ],
        },
        "variants": [
            {
                "id": "default",
                "name": "Meadow (4 colonies, 200 s)",
                "game_config": {
                    "players": players(SEATS),
                    "num_agents": SEATS,
                    "antsPerColony": 24,
                    "episodeTicks": 4800,
                    "turnTicks": 240,
                    "turnBudgetSeconds": 22,
                    "wallClockBudgetSeconds": 660,
                    "playerConnectTimeoutSeconds": 90,
                    "bonanzaTicks": [1200, 3600],
                    "fieldPath": "meadow",
                },
            },
            {
                "id": "sprint",
                "name": "Sprint meadow (4 colonies, 120 s)",
                "game_config": {
                    "players": players(SEATS),
                    "num_agents": SEATS,
                    "antsPerColony": 24,
                    "episodeTicks": 2880,
                    "turnTicks": 240,
                    "turnBudgetSeconds": 22,
                    "wallClockBudgetSeconds": 420,
                    "playerConnectTimeoutSeconds": 90,
                    "bonanzaTicks": [1200],
                    "fieldPath": "meadow",
                },
            },
        ],
        "certification": {
            "players": [{"player_id": "baseline"} for _ in range(SEATS)],
            "game_config": {
                "players": players(SEATS),
                "num_agents": SEATS,
                "seed": 42,
                "antsPerColony": 24,
                "episodeTicks": 960,
                "turnTicks": 240,
                "turnBudgetSeconds": 22,
                "wallClockBudgetSeconds": 180,
                "playerConnectTimeoutSeconds": 60,
                "bonanzaTicks": [480],
                "fieldPath": "meadow",
            },
        },
    }

    out = ROOT / "coworld_manifest_template.json"
    out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{out} {out.stat().st_size} bytes")


if __name__ == "__main__":
    main()
