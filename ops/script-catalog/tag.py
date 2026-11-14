#!/usr/bin/env python3
"""Tag padding rows (never deletes). Sets scripts.tags / catalog_status / status_reason from path rules and
exact-copy checks, then logs counts to change_log. Idempotent: recomputes every row each run.
  excluded      : vendor / borrowed / archive copies with a live copy / chat bodies identical to a disk file
  low_priority  : archive-only copies of the owner's own scripts (no live copy found) - summarized last
  active        : everything else"""
import json
import pg

ARCH = "%/Desktop/Alexus./3-Old-Linux-Archive/%"
SQL = f"""
BEGIN;
CREATE TEMP TABLE t_tags AS
SELECT s.id, ARRAY_REMOVE(ARRAY[
  CASE WHEN s.path LIKE '%/.claude/skills/synced/%' THEN 'vendor:claude-synced-skill' END,
  CASE WHEN s.path ILIKE '%/Downloads/%grok-workspace/%' THEN 'borrowed:downloaded-grok-workspace' END,
  CASE WHEN s.path LIKE '%/WebDriverAgent/%' THEN 'vendor:webdriveragent' END,
  CASE WHEN s.path LIKE '{ARCH}' THEN 'archive:old-linux-archive' END,
  CASE WHEN s.path LIKE '{ARCH}' AND s.path ~ '/\\.claude/(file-history|shell-snapshots|skills)/' THEN 'archive:tool-history' END,
  CASE WHEN s.path LIKE '{ARCH}' AND EXISTS (SELECT 1 FROM scripts b WHERE b.id <> s.id AND b.path NOT LIKE '{ARCH}'
        AND regexp_replace(b.path, '^.*/', '') IN (regexp_replace(s.path, '^.*/', ''), regexp_replace(s.path, '^.*/', '') || '.py'))
       THEN 'archive:has-live-copy' END,
  CASE WHEN s.source = 'transcript' AND EXISTS (SELECT 1 FROM scripts d WHERE d.source = 'disk' AND d.content_hash = s.content_hash)
       THEN 'chat-copy-of-disk-file' END,
  CASE WHEN length(s.body_redacted) > 12000 THEN 'long:truncated-for-model' END,
  CASE WHEN s.partial THEN 'partial:edit-fragment' END,
  CASE WHEN s.path LIKE '/private/tmp/%' OR s.path LIKE '/tmp/%' OR s.path LIKE '%/scratchpad/%' THEN 'scratch-path' END
], NULL) AS tags FROM scripts s;
UPDATE scripts s SET tags = t.tags,
  catalog_status = CASE
    WHEN t.tags && ARRAY['vendor:claude-synced-skill','borrowed:downloaded-grok-workspace','vendor:webdriveragent',
                         'archive:tool-history','archive:has-live-copy','chat-copy-of-disk-file'] THEN 'excluded'
    WHEN 'archive:old-linux-archive' = ANY(t.tags) THEN 'low_priority'
    ELSE 'active' END,
  status_reason = CASE
    WHEN 'chat-copy-of-disk-file' = ANY(t.tags) THEN 'identical to a disk file; the disk row is summarized instead'
    WHEN t.tags && ARRAY['vendor:claude-synced-skill','vendor:webdriveragent'] THEN 'vendor code, not the owner''s'
    WHEN 'borrowed:downloaded-grok-workspace' = ANY(t.tags) THEN 'downloaded third-party project'
    WHEN 'archive:tool-history' = ANY(t.tags) THEN 'archived tool history / snapshots'
    WHEN 'archive:has-live-copy' = ANY(t.tags) THEN 'old archive copy; a live copy exists'
    WHEN 'archive:old-linux-archive' = ANY(t.tags) THEN 'old archive copy, no live copy found; summarized after active rows'
    END
FROM t_tags t WHERE t.id = s.id;
"""
pg.run(SQL + "COMMIT;")
counts = pg.rows("SELECT catalog_status, count(*) n FROM scripts GROUP BY 1 ORDER BY 1")
tagc = pg.rows("SELECT tag, count(*) n FROM scripts, unnest(tags) tag GROUP BY 1 ORDER BY 2 DESC")
detail = {"status": {r["catalog_status"]: r["n"] for r in counts}, "tags": {r["tag"]: r["n"] for r in tagc}}
pg.run(f"INSERT INTO change_log(actor,action,ok,detail) VALUES('grok-bot','tag',true,{pg.lit(json.dumps(detail))}::jsonb);")
print(json.dumps(detail, indent=1))
