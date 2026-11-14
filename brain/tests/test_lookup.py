"""Offline tests for brain/lookup and brain/router (no Ollama needed: a fake word-count embedder).
Run: python3 -m unittest discover -s brain/tests -v"""
import json
import sys
import unittest
from pathlib import Path

BRAIN = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BRAIN / "lookup"))
sys.path.insert(0, str(BRAIN))
import lookup  # noqa: E402
import router  # noqa: E402

VOCAB = ["phone", "grading", "screen", "battery", "can", "bus", "socket", "async", "xero", "invoice",
         "lexus", "honda", "s2000", "ocr", "ledger", "receipt", "fido2", "landline", "smartphone", "wholesale"]


def fake_embed(text):
    words = [w.strip(".,()/?'\"").lower() for w in text.split()]
    return [float(sum(1 for w in words if w.startswith(v))) for v in VOCAB] + [0.01]


class CartridgeFiles(unittest.TestCase):
    def setUp(self):
        self.carts = lookup.load_cartridges()

    def test_all_nine_copied(self):
        self.assertEqual(len(self.carts), 9)

    def test_every_cartridge_marked_unverified(self):
        for c in self.carts:
            self.assertTrue(c["status"].startswith("UNVERIFIED"), c["_file"])
            self.assertIn("UNVERIFIED", c["warning"], c["_file"])
            self.assertNotIn("verification_command", c, c["_file"])

    def test_phone_rules_each_marked_invented(self):
        c = next(c for c in self.carts if c["_file"] == "phone_grading_matrix.json")
        self.assertIn("INVENTED", c["warning"])
        for r in c["knowledge_rules"] + c["standards"]:
            self.assertTrue(r.startswith("UNVERIFIED"), r)

    def test_no_alexus_paths_or_bridges(self):
        for f in (BRAIN / "cartridges").glob("*.json"):
            text = f.read_text()
            self.assertNotIn("/Users/", text)
            json.loads(text)
        for name in ("mail_bridge.py", "imessage_bridge.py"):
            self.assertEqual(list(BRAIN.rglob(name)), [])


class Routing(unittest.TestCase):
    def setUp(self):
        self.carts = lookup.load_cartridges()

    def test_phone_question_picks_phone_cartridge(self):
        p = lookup.pick("grading a smartphone with a cracked screen and low battery for wholesale", self.carts, fake_embed)
        self.assertIsNotNone(p.chosen)
        self.assertEqual(p.chosen["_file"], "phone_grading_matrix.json")

    def test_negative_exclusion_vetoes(self):
        p = lookup.pick("grading a smartphone screen and battery for wholesale, it is a landline", self.carts, fake_embed)
        self.assertIn("expert-phone-grading", [cid for cid, _ in p.vetoed])
        self.assertTrue(p.chosen is None or p.chosen["_file"] != "phone_grading_matrix.json")

    def test_unrelated_question_picks_nothing(self):
        p = lookup.pick("what should I cook tonight", self.carts, fake_embed)
        self.assertIsNone(p.chosen)
        self.assertTrue(p.reason)

    def test_prompt_carries_unverified_warning(self):
        c = next(c for c in self.carts if c["_file"] == "phone_grading_matrix.json")
        system, _ = router.build_prompt("q", c)
        self.assertIn("UNVERIFIED", system)

    def test_cloud_hosts_refused(self):
        self.assertTrue(lookup.is_local_url("http://alexus.local:11434"))
        self.assertTrue(lookup.is_local_url("http://127.0.0.1:11434"))
        self.assertFalse(lookup.is_local_url("https://api.example.com"))
        self.assertFalse(lookup.is_local_url("http://8.8.8.8:11434"))


if __name__ == "__main__":
    unittest.main()
