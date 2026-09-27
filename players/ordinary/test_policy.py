"""Private-view scripted player behavior."""

from __future__ import annotations

import unittest

from player import choose
from policy import ScriptedPolicy


VIEW = {
    "turn": 3,
    "you": {"delivered_last_turn": 5, "last_doctrine": None,
            "nest_block": [2, 1]},
    "field": {"blocks": [20, 11]},
    "sources": [{"block": [9, 5], "amount_seen": 41}],
}


class PlayerPolicyTest(unittest.TestCase):
    def test_scripted_choice_uses_private_view(self) -> None:
        action, source, _, user = choose(
            {"view": VIEW}, None, ScriptedPolicy(), ScriptedPolicy("driftling"),
            "", "marcher")
        self.assertEqual(source, "scripted")
        self.assertEqual(action["focus"], [9, 5])
        self.assertEqual(action["note"], "marcher: pump")
        self.assertIn('"amount_seen": 41', user)

if __name__ == "__main__":
    unittest.main()
