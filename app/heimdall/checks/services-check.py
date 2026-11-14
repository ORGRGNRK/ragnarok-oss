#!/usr/bin/env python3
"""Parser checks for bin/ragnarok-services. No live Claude, ssh, or docker."""
import getpass
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

FILE = Path(__file__).resolve().parents[1] / "bin/ragnarok-services"
loader = importlib.machinery.SourceFileLoader("services", str(FILE))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

MCP = """\
hq: https://alexus.example/mcp - ✔ Connected
money: https://alexus.example/money - ! Needs authentication
recall: http://127.0.0.1:8446 - ✘ Failed to connect — connection refused
gate: http://127.0.0.1:9999 - ✘ Failed to connect — 401 unauthorized
"""
JOBS = "123\t0\tcom.running\n-\t0\tcom.waiting\n-\t1\tcom.failed\n-\t2\tcom.needs-login.helper\n"
CONTAINERS = """\
ok-1\tUp 2 hours (healthy)
web-1\tUp 4 minutes (unhealthy)
done-1\tExited (0) 3 days ago
crash-1\tExited (1) 2 hours ago
signin-1\tExited (1) 1 hour ago needs a login
"""


class ServiceTests(unittest.TestCase):
    def test_mcp_keeps_login_ones_out(self):
        rows = m.parse_mcp(MCP)
        self.assertEqual([r["name"] for r in m.failing(rows)], ["recall"])
        self.assertEqual(sorted(r["name"] for r in m.skipped(rows)), ["gate", "money"])
        self.assertNotIn("hq", [r["name"] for r in m.failing(rows) + m.skipped(rows)])

    def test_jobs_ignore_running_and_clean_exits(self):
        rows = m.parse_jobs(JOBS)
        self.assertEqual([r["name"] for r in m.failing(rows)], ["com.failed"])
        self.assertEqual(m.skipped(rows), [])

    def test_containers_ignore_up_and_finished(self):
        rows = m.parse_containers(CONTAINERS, "Alexus")
        self.assertEqual([r["name"] for r in m.failing(rows)], ["web-1", "crash-1"])
        self.assertEqual([r["name"] for r in m.skipped(rows)], ["signin-1"])
        self.assertTrue(all(r["where"] == "Alexus" for r in rows))

    def test_container_location_is_laptop_or_alexus(self):
        laptop = m.parse_containers("box-1\tExited (1) 1 hour ago\n", "laptop")
        self.assertEqual(laptop[0]["where"], "laptop")
        self.assertRaises(ValueError, m.parse_containers, "box-1\tExited (1)\n", "cloud")

    def test_restart_plan_never_includes_a_login_service(self):
        rows = m.parse_mcp(MCP) + m.parse_jobs(JOBS) + m.parse_containers(CONTAINERS, "Alexus")
        names = [r["name"] for r in m.restart_plan(m.failing(rows))]
        self.assertEqual(names, ["com.failed", "web-1", "crash-1"])
        self.assertFalse(any(m.needs_login(n) for n in names))

    def test_odd_names_are_not_restarted(self):
        rows = [{"kind": "container", "name": "bad name;rm", "state": "fail", "detail": "Exited (1)"},
                {"kind": "job", "name": "../nope", "state": "fail", "detail": "last exit 1"},
                {"kind": "mcp", "name": "recall", "state": "fail", "detail": "connection refused"}]
        self.assertEqual(m.restart_plan(rows), [])

    def test_conf_rejects_odd_values(self):
        self.assertEqual(m.read_conf("/no/such/file"), ("alexus.local", getpass.getuser(), "alexus"))
        self.assertTrue(m.SAFE_HOST.match("alexus.example.ts.net"))
        self.assertFalse(m.SAFE_USER.match("-root"))
        self.assertFalse(m.SAFE_HOST.match("-bad"))


if __name__ == "__main__":
    unittest.main()
