"""Hive player decisions from the seat's private observation."""

from __future__ import annotations

import json
from pathlib import Path

SYSTEM = (Path(__file__).with_name("system_prompt.txt")).read_text()


class ScriptedPolicy:
    def __init__(self, kind: str = "marcher") -> None:
        self.kind = kind
        self.zero_streak = 0
        self.recalled_last = False

    def decide(self, view: dict) -> dict:
        if self.kind == "driftling":
            return self._doctrine(70, 25, 45, 70, 40, 60, note="driftling: drift")

        turn = view["turn"]
        you = view["you"]
        if turn > 0:
            self.zero_streak = self.zero_streak + 1 if you["delivered_last_turn"] == 0 else 0
        had_focus = you["last_doctrine"] is not None and you["last_doctrine"]["focus"] is not None
        if self.zero_streak >= 2 and had_focus and not self.recalled_last:
            self.recalled_last = True
            self.zero_streak = 0
            action = self._doctrine(55, 25, 10, 55, 70, 55, note="marcher: recall")
            action["recall"] = True
            return action
        self.recalled_last = False
        if turn < 3:
            return self._doctrine(55, 25, 10, 55, 70, 55, note="marcher: opening")

        bx, by = you["nest_block"]
        best = None
        best_score = -10**20
        for source in view["sources"]:
            if source["amount_seen"] <= 0:
                continue
            sx, sy = source["block"]
            score = source["amount_seen"] - 2 * max(abs(bx - sx), abs(by - sy))
            if score > best_score:
                best_score = score
                best = [sx, sy]
        cols, rows = view["field"]["blocks"]
        if best is not None:
            return self._doctrine(15, 78, 12, 32, 88, 52,
                                  focus=[min(cols - 1, max(0, best[0])),
                                         min(rows - 1, max(0, best[1]))],
                                  focus_weight=70, note="marcher: pump")
        cx, cy = cols // 2, rows // 2
        target = [min(cols - 1, max(0, bx + (cx > bx) - (cx < bx))),
                  min(rows - 1, max(0, by + (cy > by) - (cy < by)))]
        return self._doctrine(60, 25, 25, 65, 55, 60,
                              focus=target, focus_weight=40, note="marcher: probe")

    @staticmethod
    def _doctrine(scouts: int, trail_gain: int, poach: int, spread: int,
                  lay_food: int, lay_home: int, *, focus: list[int] | None = None,
                  focus_weight: int = 0, note: str) -> dict:
        return {"scouts": scouts, "trail_gain": trail_gain, "poach": poach,
                "spread": spread, "lay_food": lay_food, "lay_home": lay_home,
                "recall": False, "focus": focus, "focus_weight": focus_weight,
                "note": note, "say": ""}


def prompt_for(view: dict, strategy: str) -> tuple[str, str]:
    return SYSTEM, strategy.strip()[:4000] + "\n\n" + json.dumps(view, indent=1, ensure_ascii=False)
