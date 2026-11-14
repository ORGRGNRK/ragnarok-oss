#!/usr/bin/env python3
"""business-sync.py -- keep the two Business tables on this Mac the same.

  A = ygg-scratch-pg / ygg_business."Business"  (what the ygg-business connector reads)
  B = ragnarok-data postgres / clientdata."Business"  (data/, receipts on every change)

Matched by UID. For each item:
  - only on one side           -> copied to the other side
  - same content               -> nothing
  - different, one has a later updated_at -> the later one is copied over the older one
  - different, same or missing updated_at -> CONFLICT: listed, nothing changed (a person decides)
Never deletes anything. Every change on side B gets a write_log receipt (actor below).
NocoDB sets updated_at when you edit a row there; a plain SQL edit doesn't, so it shows up as a conflict
instead of being overwritten.

  python3 -I business-sync.py           report what it would do (changes nothing)
  python3 -I business-sync.py --apply   do it, then check both sides match
Exit: 0 in sync (or synced), 1 conflicts left, 2 couldn't run.
"""
import json
import os
import shlex
import subprocess
import sys

# Both databases live on Alexus (moved 2026-11-02); docker exec runs there over one shared ssh connection.
# RAGNAROK_DB_SSH="" runs docker locally instead.
_SSH = os.environ.get("RAGNAROK_DB_SSH", "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto "
                      "-o ControlPath=~/.ragnarok/ssh-alexus-%C -o ControlPersist=600 alexus")
def _on_alexus(cmd):
    return shlex.split(_SSH) + [shlex.join(cmd)] if _SSH else cmd

A = _on_alexus(["docker", "exec", "-i", "ygg-scratch-pg", "psql", "-U", "postgres", "-d", "ygg_business", "-X", "-At", "-v", "ON_ERROR_STOP=1"])
B = _on_alexus(["docker", "exec", "-i", "ragnarok-data-postgres-1", "psql", "-U", "kit_admin", "-d", "clientdata", "-X", "-At", "-v", "ON_ERROR_STOP=1"])
A = json.loads(os.environ["BSYNC_A"]) if os.environ.get("BSYNC_A") else A   # tests point these at throwaway copies
B = json.loads(os.environ["BSYNC_B"]) if os.environ.get("BSYNC_B") else B
# who the write_log receipts name; the Alexus systemd timer sets its own (moved off the Mac 2026-11-08)
ACTOR = os.environ.get("BSYNC_ACTOR") or "business-sync (ygg-scratch <-> data), run by Claude Code as Mac yggdrasil"
SKIP = {"id"}          # ids are each side's own row numbers
TAG = "$bsync_9Zk$"


def psql(side, sql):
    p = subprocess.run(side, input=sql, capture_output=True, text=True, timeout=120)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip()[:400])
    return p.stdout


def rows(side):
    out = psql(side, 'SELECT coalesce(json_agg(to_jsonb(b) ORDER BY b."UID"), \'[]\') FROM public."Business" b;')
    return {r["UID"]: r for r in json.loads(out)}


def content(r):
    return {k: v for k, v in r.items() if k not in SKIP}


def lit(r):
    s = json.dumps(content(r))
    assert TAG not in s
    return f"{TAG}{s}{TAG}::jsonb"


def cols(r):
    return [k for k in r if k not in SKIP]


def q(c):
    return '"' + c.replace('"', '""') + '"'


def write_sql(side_is_b, inserts, updates):
    L = ["BEGIN;"]
    if side_is_b:
        L.append(f"SET LOCAL receipt.actor = '{ACTOR}';")
    for r in inserts:
        c = ", ".join(q(x) for x in cols(r))
        L.append(f'INSERT INTO public."Business" ({c}) SELECT {c} FROM jsonb_populate_record(NULL::public."Business", {lit(r)});')
    for r in updates:
        c = ", ".join(q(x) for x in cols(r) if x != "UID")
        L.append(f'UPDATE public."Business" SET ({c}) = (SELECT {c} FROM jsonb_populate_record(NULL::public."Business", {lit(r)})) '
                 f'WHERE "UID" = {TAG}{r["UID"]}{TAG};')
    L.append("COMMIT;")
    return "\n".join(L) + "\n"


def main():
    apply = "--apply" in sys.argv
    try:
        a, b = rows(A), rows(B)
    except Exception as e:
        print(f"business-sync: can't read both tables ({e}). Are ygg-scratch-pg and ragnarok-data running?", file=sys.stderr)
        return 2
    to_a, to_b, upd_a, upd_b, conflicts = [], [], [], [], []
    for uid in sorted(set(a) | set(b)):
        ra, rb = a.get(uid), b.get(uid)
        if ra is None:
            to_a.append(rb)
        elif rb is None:
            to_b.append(ra)
        elif content(ra) != content(rb):
            ta, tb = ra.get("updated_at") or "", rb.get("updated_at") or ""
            if ta > tb:
                upd_b.append(ra)
            elif tb > ta:
                upd_a.append(rb)
            else:
                diff = [k for k in content(ra) if ra.get(k) != rb.get(k)]
                conflicts.append((uid, diff))
    print(f"scratch {len(a)} items, data {len(b)} items")
    for label, xs in (("copy to scratch (new)", to_a), ("copy to data (new)", to_b),
                      ("update scratch (data is newer)", upd_a), ("update data (scratch is newer)", upd_b)):
        if xs:
            print(f"{label}: " + ", ".join(r["UID"] for r in xs))
    for uid, diff in conflicts:
        print(f"CONFLICT {uid}: differs in {', '.join(diff)} with the same updated_at; left alone")
    if not (to_a or to_b or upd_a or upd_b):
        print("in sync" if not conflicts else "nothing to copy")
        return 1 if conflicts else 0
    if not apply:
        print("dry run: nothing changed (add --apply)")
        return 1 if conflicts else 0
    if to_a or upd_a:
        psql(A, write_sql(False, to_a, upd_a))
    if to_b or upd_b:
        psql(B, write_sql(True, to_b, upd_b))
    # new rows on B got fresh ids; keep the id counter ahead of them
    psql(B, "SELECT setval(pg_get_serial_sequence('public.\"Business\"','id'), (SELECT max(id) FROM public.\"Business\"));")
    psql(A, "SELECT setval(pg_get_serial_sequence('public.\"Business\"','id'), (SELECT max(id) FROM public.\"Business\"));")
    a2, b2 = rows(A), rows(B)
    left = [u for u in set(a2) | set(b2) if content(a2.get(u, {})) != content(b2.get(u, {}))]
    bad = [u for u in left if u not in {c[0] for c in conflicts}]
    print(f"applied. now scratch {len(a2)}, data {len(b2)}; " + ("both sides match" if not left else f"still different: {', '.join(sorted(left))}"))
    return 2 if bad else (1 if conflicts else 0)


if __name__ == "__main__":
    sys.exit(main())
