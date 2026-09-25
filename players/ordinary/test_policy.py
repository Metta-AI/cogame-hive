"""Private-view player behavior and the Jev choice wire format."""

from __future__ import annotations

import io
import json
import os
import unittest
from unittest.mock import patch

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

    def test_jev_selects_complete_doctrine(self) -> None:
        response = io.BytesIO(json.dumps({"answers": {"action": {
            "type": "choice", "probabilities": {"0": 0.1, "1": 0.9}
        }}}).encode())
        with patch.dict(os.environ, {"HIVE_JEV": "1", "TYPESAFE_API_KEY": "test"}), \
                patch("urllib.request.urlopen", return_value=response) as urlopen:
            action, source, _, _ = choose(
                {"view": VIEW}, None, ScriptedPolicy(),
                ScriptedPolicy("driftling"), "", "")
        self.assertEqual((source, action["note"]), ("jev", "driftling: drift"))
        request = urlopen.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(len(body["questions"]["action"]["criteria"]), 2)
        self.assertIn("9, 5", body["questions"]["action"]["criteria"]["0"])


if __name__ == "__main__":
    unittest.main()
