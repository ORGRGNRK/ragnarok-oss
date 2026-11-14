# script-catalog

Finds every script in the owner's AI chat transcripts and on disk, redacts secrets, and catalogs them
in Postgres (`script_catalog` DB on Alexus, container `ragnarok-pipe-db`, 127.0.0.1:5544) so a local
model can describe what each does and how scripts chain together.

- `extract.py` – deterministic extraction (no AI) into `data/staging.db` (gitignored).
  Sources: `~/.claude/projects/**/*.jsonl` (Write/Edit/MultiEdit, Bash heredocs, long Bash commands,
  fenced code ≥10 lines), `~/.codex/sessions` (if present), LocalAI app `chats.json`, and script
  files on disk (`~/Developer ~/Desktop ~/Documents ~/Downloads ~/bin ~/.local/bin ~/scripts ~/.config ~/.claude`).
- `redact.py` – replaces secret values with `[REDACTED]` before anything is stored or sent to a model.
- `load.py` – groups versions (same path → latest kept, versions counted; pathless → by content hash;
  disk copies → by hash), links disk files to the chats that produced them, upserts into Postgres.
- `summarize.py` – asks the local Ollama model for strict JSON summaries; stores them in `summaries`.
- `db/schema.sql` – tables `scripts`, `occurrences`, `script_links`, `summaries`, append-only `change_log`.

Connect (password in `.env`, gitignored, chmod 600; same file on Alexus at /opt/script-catalog/.env):

    ssh -N -L 5544:127.0.0.1:5544 grok@alexus &
    set -a; . ./.env; set +a; PGPASSWORD=$SCRIPT_CATALOG_PASSWORD psql -h 127.0.0.1 -p 5544 -U script_catalog script_catalog

or on Alexus: `podman exec -it ragnarok-pipe-db psql -U script_catalog -d script_catalog`.
Log integrity: `SELECT * FROM change_log_verify();` (empty = intact).

## Phase 2

Order: `migrate.py db/migrations/00N_*.sql` → `tag.py` → `facts.py --all` → `chain.py` → `summarize.py --all`.
Every write goes through `change_log` (actions `migration`, `tag`, `facts`, `chain`, `summarize`).

- `tag.py` – tags (never deletes) vendor/archive/borrowed/scratch copies and chat copies of disk files; sets
  `scripts.catalog_status` = `active` | `low_priority` (archive-only copies with no live copy; summarized last) |
  `excluded` (vendor, borrowed, tool-history, chat copy of a disk file; not summarized).
- `facts.py` – static extraction by code (no AI) into `script_facts`: CLI args, env vars, files read/written,
  network calls (secret-looking hosts/params masked), destructive commands, DB tables, APIs, invoked scripts.
  `risk_code` is a floor; `catalog_v.risk` = max(model risk, risk_code).
- `chain.py` – candidate edges in `script_links` (`link_kind` chain/invokes, with `reason`, `confidence`,
  `evidence`): file/table/endpoint produced by one script and consumed by another, and script-runs-script.
- `summarize.py` (prompt v3) – sends facts + edges + code (head 8000 / tail 3500 chars if longer than 12k;
  `summaries.truncated`) with emails/phones masked to qwen2.5-coder:7b on Alexus. Items naming a flag/env/file
  not in the code are dropped into `summaries.ungrounded`. Resumable (skips scripts with a valid v3 summary for
  the current hash), one JSON line per call in `SC_LOG`, flock so only one run at a time.

Full run on Alexus (as grok):

    systemd-run --user --unit=script-catalog-summarize --working-directory=/opt/script-catalog/app \
      -E SC_LOCAL=1 -E OLLAMA_URL=http://127.0.0.1:11434 -E SC_LOG=/opt/script-catalog/logs/summarize.log.jsonl \
      python3 summarize.py --all --label full-v3
    tail -f /opt/script-catalog/logs/summarize.log.jsonl      # progress; journalctl --user -u script-catalog-summarize

## Search page

`web/app.py` – stdlib HTTP server + psycopg, read-only role `script_catalog_ro` (SELECT only, no change_log,
`default_transaction_read_only=on`). DSN in `/opt/script-catalog/web.env` (chmod 600, not in git).
Bound to the Tailscale IP only: http://alexus:8449 . User unit `deploy/script-catalog-web.service`
(installed in `~grok/.config/systemd/user/`, enabled, linger on → starts at boot; IP_FREEBIND + Restart=always).

Deploy code: `git archive HEAD | ssh grok@alexus 'tar -x -C /opt/script-catalog/app'` then
`systemctl --user restart script-catalog-web`.
