# Operator notes — secure-mcp-platform

## Running

```sh
cd ~/Developer/secure-mcp-platform
npm install                                  # local only
./scripts/scratch-env.sh npm run migrate     # creates/updates schema mcp (idempotent)
./scripts/scratch-env.sh npm test            # 54 tests (core unit + scratch integration)
./scripts/scratch-env.sh node scripts/run-evals.mjs  # 10 evals, SQL key vs tools, read-only
./scripts/scratch-env.sh node dist/index.js  # stdio server (for an MCP client to spawn)
```

`scripts/scratch-env.sh` reads `~/Developer/ygg-scratch/.env` in its own process. It builds
`BUSINESS_READ_DATABASE_URL` (ygg_read) and `BUSINESS_APP_DATABASE_URL` (ygg_app), unsets
the raw variables, and `exec`s the command. Nothing is printed or written. For a real deployment,
have the owning bot's service manager provide those two env vars instead.

MCP client config shape (stdio). This is what is registered as `ygg-business` in Claude Code (user scope)
and Claude Desktop. GUI apps do not inherit the shell PATH, so node is absolute and PATH is explicit:

```json
{ "command": "./scripts/scratch-env.sh",
  "args": ["node", "dist/index.js"],
  "env": { "PATH": "/usr/local/bin:/usr/bin:/bin",
           "PLATFORM_EMBEDDER_URL": "http://127.0.0.1:11434" } }
```

On stdin EOF or SIGTERM, the server waits for in-flight calls (up to `BUSINESS_SEARCH_TIMEOUT_MS`) before
closing the pools. A client that sends a request and then closes stdin still gets its answer and receipt.

stdout carries only JSON-RPC. Logs go to stderr with `[secure-mcp-platform]` prefix, redacted.

## Receipts

Every tool call writes one row to `mcp.receipts`: tool, redacted args, ok, error_code,
duration_ms, created_at. Useful queries (as ygg_app):

```sql
select tool, ok, error_code, duration_ms, created_at from mcp.receipts order by id desc limit 20;
select tool, count(*), count(*) filter (where not ok) as errors, round(avg(duration_ms)) as avg_ms
  from mcp.receipts where created_at > now() - interval '1 day' group by 1 order by 2 desc;
```

Receipt writes are best-effort. A failure logs `receipt write failed` to stderr and does not fail the call.

## Search index

- Lazy and incremental: each `business_search_items` call embeds the query first, then the rows
  whose `(coalesce(updated_at, created_at), id)` is past `mcp.index_state` for the configured model,
  then ranks. Rows whose content hash is unchanged are skipped.
- **Re-index from scratch** for a model: delete its `index_state` row (and, to force fresh vectors,
  its vectors). The next search rebuilds.

  ```sql
  delete from mcp.index_state   where model = 'nomic-embed-text';
  delete from mcp.search_vectors where model = 'nomic-embed-text';  -- optional: forces re-embedding
  ```
- Tests use model name `stub-embedder` (and `stub-business-tests`). Those rows are test data in
  `mcp`. Leave them, or delete them with the same statements.
- Embedder down → the tool returns `upstream_unavailable`, `retry_safe: true`. Start Ollama and pull
  `nomic-embed-text`, then retry. Nothing on this Mac runs Ollama today (risk R2).

## Debugging

| Symptom | Likely cause | Action |
|---|---|---|
| `fatal: missing configuration` on start | env vars not set | launch through `scripts/scratch-env.sh` or set both URLs |
| `not_configured` … `npm run migrate` | schema `mcp` missing | run the migrate command |
| `upstream_unavailable` (database) | container down / wrong port | `docker ps`, check `YGG_PG_PORT` |
| `timeout` | query > `BUSINESS_STATEMENT_TIMEOUT_MS` or call > tool timeout | narrow the request; raise the timeout env if justified |
| `rate_limited` | burst > `BUSINESS_RATE_CAPACITY` | wait `retry_after_ms`; tune env |
| search `internal` dimension mismatch | model changed under same name | re-index (above) |

## What is risky / what breaks first

- Search on a large table (no pgvector, risk R1) breaks first under load. Watch `duration_ms` for
  `business_search_items` in receipts.
- Rollback signal: rising `ok = false` share in receipts, or any change to `public."Business"`
  checksum (`select md5(string_agg(b::text,'|' order by id)) from public."Business" b`).
- Rollback: stop the client from spawning the server. To remove all server-owned state:
  `drop schema mcp cascade` (as ygg_app). Do this only when retiring the server. It touches nothing in `public`.

## Launch-gate checklist (state at handoff, 2026-10-28)

| Gate | Evidence |
|---|---|
| Build passes | `npm run build` → `dist/index.js` |
| Tests pass | `./scripts/scratch-env.sh npm test` → 7 files, 54 tests passed, 24 titled `fails:` (offline `test/core`: 5 files, 33) |
| Schemas valid | every tool lists `inputSchema.type = "object"` with constraints, generated from zod (stdio smoke test) |
| Errors actionable | every ToolError has `code, what, why, retry_safe, fix`; unknown tool = protocol error -32602 |
| Secrets redacted | redactor masks URL credentials, secret-named keys, configured password literals; test `fails: database password is redacted…`; no password in repo/outputs (grep check) |
| No hidden state | cursors carry their own position + scope; index position in `mcp.index_state`; limiter/pools injected per server |
| 10 evals | `evals/business-evals.xml` (10 `<qa_pair>`); `scripts/run-evals.mjs` → 10/10 (answer-key SELECTs as ygg_read read-only, and the same answers derived through the tools over stdio) |
| Client registration | `claude mcp get ygg-business` → ✔ Connected; raw stdio initialize + tools/list → 6 tools; Claude Desktop entry added (backup kept next to the config) |
| Risk register | `docs/risk-register.md` |
| Operator notes | this file |

Not yet passed (needs the operator): real `nomic-embed-text` run (R2); a review of PII exposure in lead and exit contacts (R3);
the human stop-point sign-offs in the guide (see design log: none were done); and a rehearsal against the real per-project DB (R12).
