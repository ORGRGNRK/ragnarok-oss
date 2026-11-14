#!/usr/bin/env python3
"""Group staged occurrences into logical scripts and upsert them into Postgres script_catalog."""
import os, sqlite3, json, collections
import pg
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
c = sqlite3.connect(os.path.join(HERE, "data", "staging.db")); c.row_factory = sqlite3.Row
occ = [dict(r) for r in c.execute("SELECT * FROM occurrences")]

def abspath(p):
    if not p: return None
    p = p.strip("'\"")
    if p.startswith("~"): p = HOME + p[1:]
    return os.path.normpath(p) if p.startswith("/") else p

groups = collections.OrderedDict()
for o in occ:
    o["path"] = abspath(o["path"])
    if o["source"] == "disk": key = "disk:" + o["content_hash"]
    elif o["path"]: key = "path:" + o["path"]
    else: key = "hash:" + o["content_hash"]
    groups.setdefault(key, []).append(o)

rows = []
for key, os_ in groups.items():
    full = [o for o in os_ if not o["partial"]] or os_
    latest = max(full, key=lambda o: o["ts"] or "")
    ts = sorted(o["ts"] for o in os_ if o["ts"])
    src = "disk" if key.startswith("disk:") else "transcript"
    paths = sorted({o["path"] for o in os_ if o["path"]})
    rows.append(dict(
        catalog_key=key, source=src, source_tools=sorted({o["source"] for o in os_}),
        kind=latest["kind"], project=latest["project"], path=latest["path"],
        alt_paths=[p for p in paths if p != latest["path"]], language=latest["language"],
        lines=latest["lines"], content_hash=latest["content_hash"], body=latest["body"],
        secrets=latest["secrets_redacted"], partial=bool(latest["partial"]),
        first_seen=ts[0] if ts else None, last_seen=ts[-1] if ts else None,
        versions=len({o["content_hash"] for o in full}), occ=len(os_),
        sessions=sorted({o["session_id"] for o in os_ if o["session_id"]}), all=os_))

sql = ["BEGIN;"]
for r in rows:
    sql.append(f"""INSERT INTO scripts(catalog_key,source,source_tools,kind,project,path,alt_paths,language,lines,content_hash,body_redacted,secrets_redacted,partial,first_seen,last_seen,version_count,occurrence_count,sessions)
VALUES({pg.lit(r['catalog_key'])},{pg.lit(r['source'])},{pg.arr(r['source_tools'])},{pg.lit(r['kind'])},{pg.lit(r['project'])},{pg.lit(r['path'])},{pg.arr(r['alt_paths'])},{pg.lit(r['language'])},{r['lines']},{pg.lit(r['content_hash'])},{pg.lit(r['body'])},{r['secrets']},{pg.lit(r['partial'])},{pg.lit(r['first_seen'])},{pg.lit(r['last_seen'])},{r['versions']},{r['occ']},{pg.arr(r['sessions'])})
ON CONFLICT (catalog_key) DO UPDATE SET source_tools=EXCLUDED.source_tools,kind=EXCLUDED.kind,project=EXCLUDED.project,path=EXCLUDED.path,alt_paths=EXCLUDED.alt_paths,language=EXCLUDED.language,lines=EXCLUDED.lines,content_hash=EXCLUDED.content_hash,body_redacted=EXCLUDED.body_redacted,secrets_redacted=EXCLUDED.secrets_redacted,partial=EXCLUDED.partial,first_seen=EXCLUDED.first_seen,last_seen=EXCLUDED.last_seen,version_count=EXCLUDED.version_count,occurrence_count=EXCLUDED.occurrence_count,sessions=EXCLUDED.sessions,updated_at=now();""")
# occurrences: rebuilt each load
sql.append("DELETE FROM occurrences;")
for r in rows:
    for o in r["all"]:
        sql.append(f"INSERT INTO occurrences(script_id,source_tool,kind,source_file,session_id,ts,path,content_hash,lines,partial) SELECT id,{pg.lit(o['source'])},{pg.lit(o['kind'])},{pg.lit(o['source_file'])},{pg.lit(o['session_id'])},{pg.lit(o['ts'])},{pg.lit(o['path'])},{pg.lit(o['content_hash'])},{o['lines']},{pg.lit(bool(o['partial']))} FROM scripts WHERE catalog_key={pg.lit(r['catalog_key'])};")
# links: disk <-> transcript by any shared content hash or same path
sql.append("""DELETE FROM script_links WHERE link_kind='provenance';
INSERT INTO script_links(disk_id, transcript_id, src_id, dst_id, link_kind, confidence, created_by, match_type)
SELECT d.id, t.id, t.id, d.id, 'provenance', 1.0, 'load.py',
  CASE WHEN bool_or(oh.content_hash IS NOT NULL) AND bool_or(t.path = ANY(d.alt_paths || d.path)) THEN 'hash+path'
       WHEN bool_or(oh.content_hash IS NOT NULL) THEN 'hash' ELSE 'path' END
FROM scripts d JOIN scripts t ON t.source='transcript' AND d.source='disk'
LEFT JOIN occurrences oh ON oh.script_id=t.id AND oh.content_hash=d.content_hash
WHERE oh.content_hash IS NOT NULL OR t.path = ANY(d.alt_paths || d.path)
GROUP BY d.id, t.id;
UPDATE script_links SET reason = 'chat produced disk file (' || match_type || ')' WHERE link_kind='provenance' AND reason IS NULL;
UPDATE scripts s SET linked_transcript_ids = COALESCE((SELECT array_agg(transcript_id ORDER BY transcript_id) FROM script_links WHERE link_kind='provenance' AND disk_id=s.id),'{}'),
                     linked_disk_ids = COALESCE((SELECT array_agg(disk_id ORDER BY disk_id) FROM script_links WHERE link_kind='provenance' AND transcript_id=s.id),'{}');""")
stats = dict(occurrences=len(occ), scripts=len(rows),
             transcript=sum(r["source"] == "transcript" for r in rows), disk=sum(r["source"] == "disk" for r in rows),
             secrets_redacted_occurrences=sum(o["secrets_redacted"] for o in occ))
sql.append(f"INSERT INTO change_log(actor,action,ok,detail) VALUES('grok-bot','load',true,{pg.lit(json.dumps(stats))}::jsonb);")
sql.append("COMMIT;")
pg.run("\n".join(sql))
print(json.dumps(stats))
