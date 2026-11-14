"""Seed the fix memory with real failures produced by the demo project itself.

Each seed takes a *different* bug variant of examples/demo_median (not the deliberate
missing-sort bug the demo ships with), actually runs its tests in the throwaway container,
captures the real failing output, and stores it with the real diff that fixes it.
Nothing here is invented forum data."""
from __future__ import annotations

import difflib
import shutil
import tempfile
from pathlib import Path

from . import db, ollama
from .config import REPO_ROOT
from .loop import error_signature, normalize_error
from .sandbox import run_tests

DEMO = REPO_ROOT / "examples" / "demo_median"
TEST_CMD = "pytest -q -p no:cacheprovider"

# The variants are applied on top of a correct median() so each one fails for exactly one reason.
_SORT_LINE = "    values = sorted(values)\n"


def _correct_source() -> str:
    src = (DEMO / "stats.py").read_text()
    return src.replace("    n = len(values)\n", _SORT_LINE + "    n = len(values)\n", 1)


VARIANTS = [
    {
        "name": "mean-off-by-one",
        "bad": ("return sum(values) / len(values)", "return sum(values) / (len(values) - 1)"),
        "cause": "mean() divided by len(values) - 1 instead of len(values).",
    },
    {
        "name": "median-even-takes-one-middle",
        "bad": ("return (values[mid - 1] + values[mid]) / 2", "return values[mid]"),
        "cause": "For even-length input median() returned one middle element instead of averaging the two middle elements.",
    },
    {
        "name": "median-even-integer-division",
        "bad": ("return (values[mid - 1] + values[mid]) / 2", "return (values[mid - 1] + values[mid]) // 2"),
        "cause": "median() used floor division (//) for the even-length average, truncating 2.5 to 2.",
    },
]


def seed(force: bool = False, log=print) -> int:
    with db.connect() as conn:
        n = conn.execute("SELECT count(*) FROM brain.brain_fixes WHERE source = 'seed:demo_median'").fetchone()[0]
    if n and not force:
        log(f"[seed] {n} demo seed rows already present; skipping (use --force to add again).")
        return 0
    (REPO_ROOT / ".work").mkdir(exist_ok=True)
    good = _correct_source()
    added = 0
    for v in VARIANTS:
        old, new = v["bad"]
        bad = good.replace(old, new, 1)
        assert bad != good, v["name"]
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / ".work") as tmp:
            tmpd = Path(tmp)
            shutil.copy2(DEMO / "test_stats.py", tmpd / "test_stats.py")
            (tmpd / "stats.py").write_text(bad)
            res_bad = run_tests(tmpd, TEST_CMD)
            (tmpd / "stats.py").write_text(good)
            res_good = run_tests(tmpd, TEST_CMD)
        if res_bad.passed or not res_good.passed:
            log(f"[seed] {v['name']}: variant did not behave as expected (bad passed={res_bad.passed}, good passed={res_good.passed}); skipped")
            continue
        error = normalize_error(res_bad.output)
        diff = "".join(difflib.unified_diff(bad.splitlines(True), good.splitlines(True), "a/stats.py", "b/stats.py", n=1))
        rec = db.record_fix(source="seed:demo_median", project="demo_median", error_text=error,
                            cause=v["cause"], fix=diff, embedding=ollama.embed(error_signature(error), kind="document"),
                            extra={"variant": v["name"]})
        log(f"[seed] {v['name']}: real failure captured (exit {res_bad.exit_code}) -> fix #{rec['fix_id']} write_log receipt #{rec['receipt_seq']} {rec['receipt_hash'][:12]}...")
        added += 1
    return added
