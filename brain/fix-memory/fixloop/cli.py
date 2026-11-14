"""fixloop command line."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

from . import db, ollama
from .config import settings


def cmd_run(a) -> int:
    from .loop import run
    rep = run(a.project_dir, a.test, max_tries=a.max_tries, image=a.image,
              record=not a.no_record, write_back=not a.no_write_back, use_memory=not a.no_memory)
    summary = {
        "passed": rep.passed, "healed": rep.healed, "tries": rep.tries,
        "memory_hit": any(r["hit"] for r in rep.retrievals),
        "top_similarity_per_try": [r["matches"][0]["similarity"] if r["matches"] else None for r in rep.retrievals],
        "reused_fix_id": rep.reused_fix_id,
        "recorded": rep.recorded, "changed_files": rep.changed_files,
    }
    print("\n[fixloop] summary " + json.dumps(summary))
    return 0 if rep.passed else 1


def cmd_search(a) -> int:
    text = a.error if a.error != "-" else sys.stdin.read()
    from .loop import error_signature
    for f in db.search_fixes(ollama.embed(error_signature(text), kind="query"), k=a.k):
        print(f"#{f['id']} [{f['source']}] sim={f['similarity']:.3f} cause: {f['cause']}")
    return 0


def cmd_verify(a) -> int:
    ok, n, msg = db.verify_chain()
    print(("OK: " if ok else "BROKEN: ") + msg)
    return 0 if ok else 2


def cmd_receipts(a) -> int:
    """Newest write_log receipts for the brain tables (data/'s hash-chained change log)."""
    for r in db.recent_receipts(a.limit):
        what = (f"fix_id={r['fix_id']} project={r['project']}" if r['kind'] != 'fix_recorded'
                else f"fix #{r['record_id']} source={r['source']} cause={str(r['cause'])[:60]}")
        print(f"{r['seq']:>5} {r['created_at']} {r['kind']:<13} actor={r['actor']} {r['hash'][:16]}... "
              f"prev {(r['prev_hash'] or '')[:16]}... {what}")
    return 0


def cmd_stats(a) -> int:
    print(json.dumps(db.stats(), indent=2))
    return 0


def cmd_seed(a) -> int:
    from .seed_demo import seed
    print(f"[seed] added {seed(force=a.force)} row(s)")
    return 0


def cmd_reembed(a) -> int:
    """Recompute every stored search vector from its error_text (e.g. after changing the embed
    model or the signature logic). Vectors are derived data and not receipted themselves; one
    'reembed' event row is added, and that row gets a write_log receipt."""
    from .loop import error_signature
    n = db.reembed(lambda err: ollama.embed(error_signature(err), kind="document"))
    print(f"re-embedded {n} fix(es)")
    return 0


def cmd_doctor(a) -> int:
    ok = True
    print(f"ollama host: {settings.ollama_host}")
    try:
        names = ollama.tags()
        for m in (settings.coder_model, settings.embed_model):
            present = any(n == m or n.split(':')[0] == m for n in names)
            ok &= present
            print(f"  model {m}: {'present' if present else 'MISSING'}")
    except Exception as e:
        ok = False
        print(f"  unreachable: {e}")
    try:
        print(f"postgres {settings.pg_host}:{settings.pg_port} db={settings.pg_db}: {json.dumps(db.stats())}")
    except Exception as e:
        ok = False
        print(f"postgres: ERROR {type(e).__name__}")
    img = subprocess.run(["docker", "image", "inspect", settings.runner_image], capture_output=True)
    print(f"runner image {settings.runner_image}: {'present' if img.returncode == 0 else 'MISSING (run brain/fix-memory/scripts/setup.sh)'}")
    ok &= img.returncode == 0
    return 0 if ok else 1


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="fixloop", description="Build-time self-healing test loop with fix memory.")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="test a project; on failure retrieve past fixes, ask the local model, retry")
    r.add_argument("project_dir")
    r.add_argument("--test", required=True, help="test command run inside the container, e.g. 'pytest -q'")
    r.add_argument("--max-tries", type=int, default=None, help=f"total test runs (default {settings.max_tries})")
    r.add_argument("--image", default=None, help=f"runner image (default {settings.runner_image})")
    r.add_argument("--no-record", action="store_true", help="do not write the fix to memory")
    r.add_argument("--no-memory", action="store_true", help="do not retrieve past fixes (for A/B comparison)")
    r.add_argument("--no-write-back", action="store_true", help="leave the project untouched; healed copy stays in .work/")
    r.set_defaults(fn=cmd_run)
    s = sub.add_parser("search", help="search fix memory for an error ('-' reads stdin)")
    s.add_argument("error"); s.add_argument("-k", type=int, default=3); s.set_defaults(fn=cmd_search)
    sub.add_parser("verify", help="verify the data layer's receipt chains (kit_verify)").set_defaults(fn=cmd_verify)
    rc = sub.add_parser("receipts", help="show recent brain receipts from write_log"); rc.add_argument("--limit", type=int, default=10); rc.set_defaults(fn=cmd_receipts)
    sub.add_parser("stats", help="counts of fixes and receipts").set_defaults(fn=cmd_stats)
    sd = sub.add_parser("seed-demo", help="seed memory from real failures of the demo project's bug variants")
    sd.add_argument("--force", action="store_true"); sd.set_defaults(fn=cmd_seed)
    sub.add_parser("reembed", help="recompute stored embeddings from error text").set_defaults(fn=cmd_reembed)
    sub.add_parser("doctor", help="check Ollama models, Postgres, runner image").set_defaults(fn=cmd_doctor)
    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
