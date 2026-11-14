#!/usr/bin/env python3
"""Apply a migration file in one transaction and record it in change_log. Usage: migrate.py db/migrations/002_phase2.sql"""
import sys, os, json, hashlib
import pg
f = sys.argv[1]; body = open(f).read()
name = os.path.basename(f)
done = pg.query(f"SELECT count(*) FROM change_log WHERE action='migration' AND detail->>'file'={pg.lit(name)}")[0][0]
if done != "0" and "--force" not in sys.argv: sys.exit(f"{name} already applied")
detail = json.dumps({"file": name, "sha256": hashlib.sha256(body.encode()).hexdigest()})
pg.run("BEGIN;\n" + body + f"\nINSERT INTO change_log(actor,action,ok,detail) VALUES('grok-bot','migration',true,{pg.lit(detail)}::jsonb);\nCOMMIT;")
print("applied", name)
