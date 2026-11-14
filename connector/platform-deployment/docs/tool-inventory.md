# Tool inventory — secure-mcp-platform

Phase A/B design record. Scope reading picked by the executor: the project lives in
`~/Developer/secure-mcp-platform`; copies of the docs, evals and a source tarball go to the
conveyor outputs folder at the end. Only the **scratch** `ygg_business` database
(container `ygg-scratch-pg`, 127.0.0.1:5547) is used.

- Transport: stdio. Capabilities: tools only (no resources/prompts in v1).
- SDK: `@modelcontextprotocol/sdk` pinned at exactly `1.32.2` (low-level `Server`, so input JSON Schemas and the two error classes are explicit).
- Naming: `business_<verb>_<noun>`, verbs `list | get | search | summarize`. Names are stable; the shared core rejects names that break the rule.
- Reads go through the read-only role (`ygg_read`, session `default_transaction_read_only=on`). Writes (receipts, search cache) go only to schema `mcp` through the owner role (`ygg_app`).

## Tools

| Tool | Purpose | Input schema (JSON Schema, `additionalProperties: false`) | Output fields (`structuredContent`) | Errors (tool-level `code`) | Read/write |
|---|---|---|---|---|---|
| `business_list_items` | Page through inventory items in id order, optionally filtered | `limit` int 1–100 (default 20); `cursor` string (opaque); `status` string; `category` string (filters exact, case-insensitive) | `items[]` (id, uid, item, category, condition, status, platform, buy_price, parts_invested, total_cost_basis, list_price, sold_price, sold_date, net_profit, acquisition_date, updated_at), `count`, `next_cursor` (string or null) | invalid_argument, invalid_cursor, timeout, rate_limited, upstream_unavailable | read (`public.business_with_totals`) + receipt |
| `business_get_item` | Full details of one item | exactly one of `id` int ≥1 or `uid` string | `item` (list fields + repair_status, intended_action, listed_on, sale_pricing, imei_status, imei_last4, imei2_last4, battery_pct, miles, notes, created_at, check_flag, check_notes, confirmed) | invalid_argument, not_found, timeout, rate_limited, upstream_unavailable | read + receipt |
| `business_summarize_items` | Counts and money totals grouped by a column | `group_by` enum status/category/platform/condition (required); `status`, `category` filters | `group_by`, `groups[]` (key or null, count, buy_total, parts_total, sold_total, realized_net_profit), `totals` | invalid_argument, timeout, rate_limited, upstream_unavailable | read + receipt |
| `business_list_leads` | Page through purchase leads | `limit` 1–100; `cursor`; `status` | `items[]` (id, lead, contact, device, their_ask, my_offer, est_grade, status, next_touch, source, notes, item_id, updated_at), `count`, `next_cursor` | invalid_argument, invalid_cursor, timeout, rate_limited | read (`public."Leads"`) + receipt |
| `business_list_exit_profiles` | Page through exit profiles (sell channels) | `limit` 1–100; `cursor`; `active_only` boolean (default false) | `items[]` (id, exit_name, exit_type, buyer_contact, grade_floor, accepts_bad_esn, accepts_no_power, price_basis, fees_costs, turnaround, active, notes, updated_at), `count`, `next_cursor` | invalid_argument, invalid_cursor, timeout, rate_limited | read (`public."Exit Profiles"`) + receipt |
| `business_search_items` | Semantic search; lazily embeds new/changed items first | `query` string 1–200 (required); `limit` int 1–25 (default 5) | `query`, `items[]` (list fields + `score`), `count`, `index` {model, embedded_now, unchanged, storage} | invalid_argument, upstream_unavailable (embedder down, `retry_safe: true`), timeout, internal (dimension mismatch) | read Business + writes only `mcp.search_vectors`, `mcp.index_state` + receipt |

Every result has `content[0]` = one-line text summary and `structuredContent` = the object above.

## Error shape

Tool execution errors return `isError: true`, a text line, and
`structuredContent.error = { code, what, why, retry_safe, fix }` (plus `retry_after_ms` for
rate limits). Codes: `invalid_argument`, `invalid_cursor`, `not_found`, `timeout`,
`rate_limited`, `upstream_unavailable`, `permission_denied`, `not_configured`, `internal`.

Protocol errors (JSON-RPC `error`, code -32602) are used only when the request names a tool that
does not exist. The SDK handles malformed JSON-RPC itself.

## State and handles

No hidden state. The only multi-call flow is pagination. `next_cursor` is base64url JSON
`{v, s: scope, k: last_id}`. The scope binds it to the tool and its filters, so reusing it with
different filters gives `invalid_cursor`. Cursors never expire: keyset paging on `id` stays
valid even when rows are added. The search index position lives in the database
(`mcp.index_state`), not in process memory.

## Configuration (environment)

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `BUSINESS_READ_DATABASE_URL` | yes | — | Postgres URL for the read-only role (`ygg_read`) |
| `BUSINESS_APP_DATABASE_URL` | yes | — | Postgres URL for the owner role (`ygg_app`); used only for schema `mcp` |
| `BUSINESS_EMBEDDER_URL` | no | `http://127.0.0.1:11434` | Ollama-compatible API base URL |
| `BUSINESS_EMBEDDER_MODEL` | no | `nomic-embed-text` | Embedding model name (also the index key) |
| `BUSINESS_STATEMENT_TIMEOUT_MS` | no | 5000 | Postgres `statement_timeout` per query |
| `BUSINESS_TOOL_TIMEOUT_MS` | no | 10000 | Per-call deadline for non-search tools |
| `BUSINESS_SEARCH_TIMEOUT_MS` | no | 120000 | Per-call deadline for search (includes indexing) |
| `BUSINESS_EMBEDDER_TIMEOUT_MS` | no | 15000 | Per-embedding HTTP timeout |
| `BUSINESS_RATE_CAPACITY` / `BUSINESS_RATE_PER_SECOND` | no | 30 / 5 | Token-bucket burst / refill |

## Deferred (not in v1)

- `Phone Grades` table: no tool yet. It is bot-written grading data, and it is empty in scratch.
- Any mutating tool (create/update items, leads). A mutating tool would need an approval design first.
- Resources/prompts.
