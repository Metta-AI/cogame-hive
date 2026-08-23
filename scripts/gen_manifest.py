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

    # A real JSON Schema document, not a bare property bag: the CLI requires
    # `tokens` in `required`, a string-array `tokens` property with integer
    # minItems/maxItems bounds, and it validates every variant and the
    # certification fixture against this schema with synthetic tokens injected.
    config_schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "required": ["tokens", "players"],
        "properties": {
            "tokens": {
                "description": "One connection token per seat, injected by the "
                               "runner and indexed by slot.",
                "type": "array",
                "minItems": SEATS,
                "maxItems": SEATS,
                "items": {"type": "string", "minLength": 1},
            },
            "players": {
                "description": "One player display-name object per seat, "
                               "indexed by slot.",
                "type": "array",
                "minItems": SEATS,
                "maxItems": SEATS,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["name"],
                    "properties": {"name": {"type": "string", "minLength": 1}},
                },
            },
            "num_agents": {
                "description": "Colonies. Hive seats exactly four: the corner "
                               "set is closed under both mirror axes, so every "
                               "colony's situation is identical.",
                "type": "integer", "minimum": SEATS, "maximum": SEATS,
                "default": SEATS,
            },
            "seed": {
                "description": "Pins the seat-to-nest permutation, the orbit "
                               "spawn cells, the kernel tie-noise and the "
                               "release-bearing draw. Unpinned means randomized.",
                "type": "integer",
            },
            "antsPerColony": {
                "description": "Bodies per colony. 24 in every shipped variant.",
                "type": "integer", "minimum": 1, "maximum": 255, "default": 24,
            },
            "episodeTicks": {
                "description": "Episode length in 24 Hz ticks.",
                "type": "integer", "minimum": 240, "maximum": 14400,
                "default": 4800,
            },
            "turnTicks": {
                "description": "Ticks between decision turns; one doctrine per "
                               "colony per turn.",
                "type": "integer", "minimum": 24, "maximum": 1200,
                "default": 240,
            },
            "antStepTicks": {
                "description": "An ant acts once every this many ticks.",
                "type": "integer", "minimum": 1, "maximum": 8, "default": 2,
            },
            "cellPx": {
                "description": "Pixels per cell on the rendered board.",
                "type": "integer", "minimum": 1, "maximum": 32, "default": 8,
            },
            "pheromoneMax": {
                "description": "Saturation value of a pheromone cell.",
                "type": "integer", "minimum": 1, "maximum": 65535,
                "default": 4000,
            },
            "pheromoneFloor": {
                "description": "A decayed cell below this becomes exactly 0.",
                "type": "integer", "minimum": 0, "maximum": 1000, "default": 4,
            },
            "pheromoneDecayNum": {
                "description": "Decay numerator: p <- (p * n) shr 8, applied "
                               "every decayPeriodTicks ticks.",
                "type": "integer", "minimum": 1, "maximum": 256, "default": 248,
            },
            "decayPeriodTicks": {
                "description": "Ticks between decay sweeps.",
                "type": "integer", "minimum": 1, "maximum": 240, "default": 8,
            },
            "nestSenseCells": {
                "description": "Path integration range: beyond this a laden ant "
                               "only knows the way home by the home trail.",
                "type": "integer", "minimum": 0, "maximum": 80, "default": 12,
            },
            "maxOrbits": {
                "description": "Live four-source orbits allowed at once.",
                "type": "integer", "minimum": 0, "maximum": 12, "default": 3,
            },
            "sourceSpawnPeriod": {
                "description": "Ticks between orbit spawn opportunities.",
                "type": "integer", "minimum": 24, "maximum": 4800,
                "default": 240,
            },
            "sourceAmount": {
                "description": "Units in each source of an orbit.",
                "type": "integer", "minimum": 1, "maximum": 10000, "default": 60,
            },
            "sourceLifeTicks": {
                "description": "Ticks before an orbit source expires.",
                "type": "integer", "minimum": 24, "maximum": 14400,
                "default": 1440,
            },
            "minNestClearance": {
                "description": "Chebyshev cells an orbit must keep from every "
                               "nest centre.",
                "type": "integer", "minimum": 0, "maximum": 60, "default": 14,
            },
            "bonanzaTicks": {
                "description": "Ticks at which the four centre-block bonanza "
                               "sources spawn.",
                "type": "array", "items": {"type": "integer", "minimum": 0},
                "maxItems": 8, "default": [1200, 3600],
            },
            "bonanzaAmount": {
                "description": "Units in each bonanza source.",
                "type": "integer", "minimum": 1, "maximum": 10000,
                "default": 100,
            },
            "bonanzaLifeTicks": {
                "description": "Ticks before a bonanza source expires.",
                "type": "integer", "minimum": 24, "maximum": 14400,
                "default": 900,
            },
            "raidRadius": {
                "description": "Chebyshev cells around a nest inside which a "
                               "lifted unit counts as a raid on that colony.",
                "type": "integer", "minimum": 0, "maximum": 80, "default": 20,
            },
            "trailWarThreshold": {
                "description": "Block-mean food trail two colonies must both "
                               "exceed for a trail_war event.",
                "type": "integer", "minimum": 1, "maximum": 65535,
                "default": 800,
            },
            "turnBudgetSeconds": {
                "description": "Wall-clock budget for one decision turn, "
                               "including the LLM batch and its one retry.",
                "type": "number", "minimum": 1, "maximum": 120, "default": 22,
            },
            "wallClockBudgetSeconds": {
                "description": "Engine hard stop. Past it the episode ends "
                               "deadline/wall_clock with the counters as they "
                               "stand.",
                "type": "number", "minimum": 10, "maximum": 1200,
                "default": 660,
            },
            "playerConnectTimeoutSeconds": {
                "description": "Bounded wait for the seats to connect before "
                               "the match starts anyway.",
                "type": "number", "minimum": 1, "maximum": 600, "default": 90,
            },
            "episodeTimeoutSeconds": {
                "description": "Wall clock the game assumes the platform allows "
                               "when COWORLD_TIMEOUT_SECONDS is absent, which "
                               "it always is for the game container.",
                "type": "integer", "minimum": 60, "maximum": 6000,
                "default": 1200,
            },
            "fieldPath": {
                "description": "Name of the authored field spec under data/.",
                "type": "string", "minLength": 1, "default": "meadow",
            },
            "showPlayerLabels": {
                "description": "Whether the SPECTATOR feed carries real policy "
                               "names beside the colony aliases.",
                "type": "boolean", "default": True,
            },
            "gameOverTicks": {
                "description": "Ticks the endcard holds after the final tick.",
                "type": "integer", "minimum": 0, "maximum": 1200, "default": 96,
            },
        },
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

    global_protocol = (
        "# Hive - spectator channel (hive.global.v1)\n\n"
        "`WS /global` streams one JSON snapshot per turn and one on every "
        "connection:\n\n"
        "```json\n"
        "{\"type\": \"state\", \"game\": \"hive\", "
        "\"protocol\": \"hive.global.v1\",\n"
        " \"t\": 1680, \"turn\": 7, \"ticks\": 4800, "
        "\"turns\": 20, \"fps\": 24,\n"
        " \"speeds\": [1,2,3,4,8,16],\n"
        " \"field\": {\"cols\": 160, \"rows\": 88, \"cell_px\": 8, "
        "\"blocks\": [20,11],\n"
        "           \"block_cells\": 8, \"rock\": [ ... 11 rows of 20 chars "
        "... ]},\n"
        " \"colonies\": [{\"seat\": 0, \"nest\": 0, \"alias\": "
        "\"Amber\", \"colour\": \"#f2c14e\",\n"
        "               \"cell\": [16,12], \"player\": \"daveey\", "
        "\"delivered\": 118,\n"
        "               \"carrying\": 6, \"scouts\": 4, \"doctrine\": "
        "{ ... },\n"
        "               \"doctrine_source\": \"llm\"}, ... 4 ... ],\n"
        " \"ants\": [[cx, cy, state, colony], ... 96 ... ],\n"
        " \"sources\": [{\"id\": 12, \"cell\": [76,43], "
        "\"amount\": 41, \"spawn_amount\": 60}],\n"
        " \"scoreboard\": [{\"colony\": \"Amber\", "
        "\"delivered\": 118}, ... ],\n"
        " \"started\": true, \"done\": false, "
        "\"connected\": [true,true,true,true],\n"
        " \"events\": [ ...the last 40 events... ]}\n"
        "```\n\n"
        "Ant state codes: 0 searching forager, 1 searching scout, 2 carrying, "
        "3 held by recall.\n\n"
        "Real player names appear only in `colonies[].player`, and only when "
        "`showPlayerLabels` is set; every in-game surface sees the colony "
        "alias.\n\n"
        "`GET /client/global` is a real browser page over the same feed. "
        "`GET /client/player` is the seat's documentation page and "
        "deliberately never opens the player websocket. `/healthz` and "
        "`/global` keep answering for a 20 s shutdown grace after the "
        "artifacts are written.\n\n"
        "Replays are a STATIC wasm bundle, never a pod: the viewer re-runs "
        "the same integer sim from the recorded doctrine stream in the "
        "browser and verifies its own re-derivation against the u32 digest in "
        "every keyframe. It contacts nothing but the S3 URL it was given.\n"
    )

    def variant(vid, name, description, ticks, wall, bonanzas):
        return {
            "id": vid,
            "name": name,
            "description": description,
            "game_config": {
                "players": players(SEATS),
                "num_agents": SEATS,
                "antsPerColony": 24,
                "episodeTicks": ticks,
                "turnTicks": 240,
                "turnBudgetSeconds": 22,
                "wallClockBudgetSeconds": wall,
                "playerConnectTimeoutSeconds": 90,
                "bonanzaTicks": bonanzas,
                "fieldPath": "meadow",
            },
        }

    manifest = {
        "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/"
                   "src/coworld/coworld_manifest_schema.json",
        "tags": ["swarm", "stigmergy", "foraging", "pheromones",
                 "one-policy-many-bodies", "llm-driven", "real-time",
                 "four-player", "constant-sum"],
        # Top-level, not under `game`: the platform kills a hosted episode at
        # this many minutes, and hive settles inside 60% of it (660 s).
        "episode_timeout_minutes": 20,
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
            "runnable": {
                "type": "game",
                "image": image,
                "run": ["/bin/hive"],
                # The hosted game holds the LLM client, so the Coworld secret
                # is injected here. Offline (local certify, the docker smoke)
                # the URI does not resolve, the client disables itself on
                # first discovery and every seat falls back to the scripted
                # doctrine - which is why certification passes with no
                # credentials at all.
                "env": {
                    "ANTHROPIC_API_KEY_URI":
                        "secret://coworld/hive/anthropic_api_key"
                },
                "source_url": source_url,
            },
            "replay_viewer": {"bundle": "static-replay-viewer"},
            "config_schema": config_schema,
            "results_schema": results_schema,
            "protocols": {
                "player": {"type": "text", "value": read("docs/PROTOCOL.md")},
                "global": {"type": "text", "value": global_protocol},
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
        },
        # Bundled player runnables live at the TOP level, and the certifier's
        # `players-run` step requires every one of them to be seated by at
        # least one certification slot - so hive ships exactly the one the
        # fixture seats four times.
        "player": [
            {
                "id": "baseline",
                "type": "player",
                "name": "Hive Marcher Baseline",
                "description": (
                    "The scripted marcher: opens wide with scouts near 60 and "
                    "a weak trail, inverts to a hard pump the moment a cache "
                    "shows up in its sources list, and recalls for one turn "
                    "when deliveries collapse. Registers its seat as "
                    "rule-based, so the game server plays it "
                    "deterministically with no LLM. It is also the fallback "
                    "every LLM seat lands on."
                ),
                "image": image,
                "run": ["/bin/hive-player"],
                "env": {"PLAYER_SCRIPTED": "marcher"},
                "source_url": source_url,
            }
        ],
        "variants": [
            variant("default", "Meadow (4 colonies, 200 s)",
                    "The full meadow: 4800 ticks, twenty decision turns, two "
                    "centre bonanzas.", 4800, 660, [1200, 3600]),
            variant("sprint", "Sprint meadow (4 colonies, 120 s)",
                    "A cheap ladder round: 2880 ticks, twelve turns, one "
                    "centre bonanza. Same four seats, same 24 ants.",
                    2880, 420, [1200]),
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
