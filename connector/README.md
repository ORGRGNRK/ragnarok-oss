# connector/ — the one doorway to the data (MCP server, TypeScript)

## What this is

This is the **only** way an AI (Claude Desktop, Cursor, a local model, …) reaches Ragnarok's data.
It is an MCP server: the AI asks it to run a *tool* ("list the items", "update this record"), and the
connector does it against the one Postgres database in `../data`.

Every tool call — good, refused, or broken — leaves a **receipt** in `access_log`, the same
hash-chained, locked logbook `data/` already uses. Every change to data also leaves a receipt in
`write_log` (the database writes that one itself). So you can always answer "which AI asked for
what, when, and what happened" with `cd ../data && ./kit verify`.

When a tool answers, its last line names its receipt, for example `[access receipt: access_log #42]`.

## The tools (19)

Names follow one pattern: **area_verb_noun**.

**Your client tables** (the ones described in `data/client/schema.json`):

| Tool | What it does | Needs the write key? |
|---|---|---|
| `data_list_tables` | Lists the tables and how many records each has | no |
| `data_describe_table` | Shows a table's fields and their rules | no |
| `data_list_records` | Lists records, with simple filters | no |
| `data_get_record` | Opens one record and its change history | no |
| `data_search_records` | Text search across a table | no |
| `data_verify_receipts` | Checks the receipt logbook is intact | no |
| `data_create_records` | Adds records, reads them back, reports CONFIRMED + receipt | **yes** |
| `data_update_records` | Changes records, reads them back, reports CONFIRMED + receipt (old and new value kept) | **yes** |
| `data_archive_record` | Removes a record from the table (kept whole in `archive`), **only** after a person runs `./kit approve CODE` | **yes** |

**The business (resale) tables** — Business items, Leads, Exit Profiles. These are **read-only** for
every AI; they cannot change them at all (the database login itself has no write permission there).

| Tool | What it does |
|---|---|
| `business_list_items` | Pages through items (filter by status or category) |
| `business_get_item` | One item by id or UID (IMEIs shown as last 4 digits only) |
| `business_summarize_items` | Totals: count, cost, sold, profit, grouped by status/category/platform |
| `business_list_leads` | Pages through leads |
| `business_list_exit_profiles` | Pages through exit profiles (buyers you sell to) |
| `business_search_items` | Plain-language search ("cracked iphone 13") |

**The fix memory** (`brain/fix-memory`: past test failures and the change that fixed them, in the same
Postgres). These four used to be a second MCP server (`fixloop-mcp`, Python); since 2026-10-30 they
live here (`src/brain.ts`) so Ragnarok has one MCP server. Same tools, same arguments, same search.

| Tool | What it does | Needs the write key? |
|---|---|---|
| `brain_search_fixes` | The `k` (1–10, default 3) stored fixes whose error looks most like `error_text`, each with its receipt hash | no |
| `brain_list_receipts` | The newest fix-memory receipts from `write_log` (`limit` 1–100, default 10) | no |
| `brain_verify_receipts` | Recomputes both receipt chains: `{ok, checked, message}` | no |
| `brain_record_fix` | Stores `error_text` → `cause` → `fix` (a diff), optional `project`; the database receipts it; read back and reported CONFIRMED | **yes** |

Every tool takes `actor` (who is calling, e.g. "Claude Desktop") and, optionally, `session`.
Both are written on the receipt. A call without `actor` is refused (and that refusal is receipted too).

**Which model was it?** Every receipt (`access_log`, receipt format 2 since 2026-10-30) has two model columns:

| Column | What it holds | Trust it? |
|---|---|---|
| `model_reported` | The model name **the model API itself put in its response**, when this server made the model call. Today only the brain tools do (their embedding call to Ollama). | As far as you trust that local model server. |
| `model_claimed` | What the **client says** it runs on: the optional `model_claimed` argument (max 200 characters) every tool accepts. Never checked. | No: a **claim**, like `actor`. |

An outside MCP client (Claude Desktop, Cursor, ...) never gets a `model_reported`: the server can't see
which model drives it, so that column stays NULL and only the client's claim (if any) is stored.
Both columns are covered by the receipt's hash. Receipts written before the change keep receipt
format 1 (`receipt_v` NULL) and still verify with the hashes they were written with (`data/db/receipts_v2.sql`).

A read-only key sees the 15 tools without "**yes**" above. A full key sees all 19.

## Search needs a local model

`business_search_items` turns text into numbers with **Ollama on this Mac** (model `nomic-embed-text`,
`ollama pull nomic-embed-text`). It will only talk to a local address (localhost, this machine, or
a private LAN address) — it refuses cloud services on purpose, so your data never leaves your
machines. If Ollama isn't running, search says so plainly; every other tool still works.
Setting: `BUSINESS_EMBEDDER_URL` in `data/.env` (default `http://host.docker.internal:11434`).

`brain_search_fixes` and `brain_record_fix` use the same kind of local model (`nomic-embed-text`,
through Ollama's `/api/embed`, exactly as `fixloop` does, so both find each other's fixes).
Settings: `BRAIN_OLLAMA_URL` (empty = `BUSINESS_EMBEDDER_URL`; e.g. the LAN box
`http://alexus:11434`) and `BRAIN_EMBED_MODEL`. Same local-only rule. If the model can't be
reached, those two tools say so and nothing is stored; the other two still work.

## How to run it

You don't start it by hand: `cd ../data && ./kit up` builds and starts it next to Postgres.
Apps on this Mac connect to `http://127.0.0.1:8891/mcp` with the access key kept in `data/.env`
(the full key or the read-only key). Claude Desktop / Claude Code can instead run `../data/kit mcp-stdio`
(build once first: `cd connector && npm ci && npm run build`).

## How to test it

```bash
cd ~/Developer/ragnarok/data
./kit test
```

On a throwaway copy (deleted afterwards) it runs:

1. **71 unit + integration tests** (vitest, from ygg-mcp-business plus one new one) against made-up
   business rows (`test/fixtures/business-fake.sql`, never your real data).
2. **72 end-to-end checks** (`test/e2e.ts`), including the new section "3b": a business tool call
   writes an `access_log` receipt that names the tool, the actor, the key used and the arguments;
   its fingerprint is recomputed independently and links to the receipt before it; failed and
   refused business calls are receipted too; and the whole log still verifies INTACT.
3. 11 more checks from outside the stack (keys, logs never contain secrets, `./kit approve` needs a
   person at a terminal, tamper detection).

Good result: `ALL TESTS PASSED`.

## Where the code came from (2026-10-30)

| Part | From | Notes |
|---|---|---|
| `src/server.ts`, `tools.ts`, `db.ts`, `config.ts`, `schema.ts`, `http.ts`, `stdio.ts`, `cli.ts`, `test/e2e.ts` | `data/mcp` (moved here with `git mv`) | `server.ts` rewritten to serve both tool families from one place; tools renamed `data_*` |
| `src/core/*` (errors, redaction, validation, timeouts, rate limit, cursors, search index, ToolHost) | `~/Developer/ygg-mcp-business` @ `0bd42d5` (copied) | receipts now go to `access_log` instead of ygg's separate, un-chained `mcp.receipts` table |
| `src/business/*` and the vitest tests | same | 6 tools kept, 2 dropped (below); tests now use fake rows instead of a real scratch database |
| `src/brain.ts`, `test/brain/brain.test.ts`, `test/brain-smoke.ts` | `brain/fix-memory/fixloop/mcp_server.py` (`fixloop-mcp`, 2026-10-30) | ported to TypeScript: same 4 tools, SQL, embedding call and error signature; receipting is now the connector's (zod-checked `actor`, refusals receipted, `brain_record_fix` hidden from read-only keys and read back after COMMIT). The Python server is a stub that points here. |

**Dropped, on purpose:**

- `business_get_network_diagnostics` — needed a `transport_log` table whose setup script replaced the
  receipt chain's fingerprint function (would break `./kit verify`) and opened it to every login. It
  also duplicated what `access_log` already records.
- `ragnarok_get_client_stack` — called itself "get" but actually created client folders and started
  Docker stacks (old ports, old client-kit path) and told the AI to read `.env` secrets. An AI tool
  must never do that on its own ("AI outputs are proposals").
- ygg's own `index.ts`/`http.ts` (this folder already has transports), its `migrate.ts` and `sql/`
  (the business tables are now set up by `data/db/business.sql`), `hooks/`, `deploy/`, `evals/`, `docs/`.
- `~/Developer/muse-mcp-bridge/src/lib.ts` — **not merged.** It is a client that sends your data to
  Meta's cloud Muse model (`api.meta.ai`), which breaks the "no cloud AI" rule, and it isn't server
  code. Its one good idea (callers always say who they are and which session) is now built in: the
  `actor`/`session` arguments on every tool.
