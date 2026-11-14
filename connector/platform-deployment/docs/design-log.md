# Design log — phases A–E (without-human run, 2026-10-28)

The operator's guide has human stop points. This build followed the WITHOUT-HUMAN form: the
phases were run and their decisions recorded here, but no teach-back was done. **Nobody has
signed off on the stop points.** The operator should read this log before relying on the server.

## A — Research (what was examined)

- Scratch Postgres `ygg-scratch-pg` (postgres:17, 127.0.0.1:5547), database `ygg_business`.
  Inspected with `\d` as ygg_read: `public."Business"` (92 rows, ids 1–92, no null `updated_at`),
  `"Leads"` (0), `"Exit Profiles"` (0), `"Phone Grades"` (0), view `business_with_totals`
  (adds `Total_Cost_Basis` and `Net_Profit` = sold − buy − parts, and omits Check, Check_Notes and Confirmed).
- Grants: ygg_read has SELECT on Business. ygg_app owns the database and can create schemas.
- Extensions: no `vector`. No Ollama on this Mac (task facts; not re-probed beyond the
  connection-refused path used in tests).
- SDK: `@modelcontextprotocol/sdk` 1.32.2 was the latest on npm on 2026-10-28. zod 4.6.7 provides
  `z.toJSONSchema`. TypeScript 5.9.3 was picked over 7.x as the boring choice.

## B — Design decisions

| Decision | Choice | Rejected alternative and why |
|---|---|---|
| SDK API | low-level `Server` + own `ToolHost` | `McpServer.registerTool`: its validation behaviour for bad args has changed across 1.x releases. Owning dispatch keeps the protocol/tool error split explicit. |
| Schemas | zod objects (`.strict()`) → JSON Schema | hand-written JSON Schema plus a separate validator would drift |
| Bad arguments | tool error `invalid_argument` | protocol error: the model cannot read and fix those as easily |
| Unknown tool | protocol error -32602 | tool error: there is no tool to own it |
| Paging | keyset on id, opaque scoped cursor | offset paging: shifts when rows are added |
| Search storage | `real[]` in `mcp.search_vectors`, cosine in TS | pg_trgm keyword search: not semantic. pgvector: not installed. |
| Index trigger | lazy, inside search, `(updated_at, id)` watermark + content hash | background job: hidden moving part, nothing to own it |
| Writes | only schema `mcp` via ygg_app | separate DB: the design wants one DB per project |
| Rate limit | token bucket per server instance, injected | module singleton: tests would starve each other |

## C — Implementation

Core and Business folders are separate (`src/core` contains no Business-specific code). Request
flow: tools/call → ToolHost lookup → limiter → zod → handler under timeout → summary +
structuredContent (redacted) → receipt.

## D — Tests (matrix)

| Area | Success cases | Failure cases (`fails:`) |
|---|---|---|
| core errors/redaction | ToolError shape/text, DB error mapping, URL/key/literal redaction | — |
| core validate/timeout/limit/cursor | defaults, JSON Schema, refill, cursor round-trip | invalid input, timeout, rate limit, cursor scope mismatch, garbage cursor |
| core host/receipts | list, call result shape, receipt write, bad-name rejection, receipt failure tolerated | unknown tool, missing arg, wrong type, timeout, rate limit, password redacted |
| core search | cosine, Ollama request shape + nomic prefixes | embedder unreachable, model missing |
| business (scratch DB) | six tools listed, full paging without duplicates, filters, get by id/uid, totals = SQL, leads/exits, one receipt per call | unknown tool, missing arg, wrong type, out-of-range limit, malformed/reused cursor, nonexistent id, embedder unreachable, DB statement timeout, rate limit, password not in receipts |
| search (scratch DB) | first search embeds all 92, second embeds 0, ranking, rewind → exactly 1 re-embedded | empty query rejected before embedding |

Found and fixed at client registration (2026-10-28): on stdin EOF the server closed its pools while a
call was still in flight. The call's receipt failed and its response was never sent. `ToolHost.drain()` now
waits for in-flight calls before shutdown (`test/core/drain.test.ts`, 2 tests). Suite total: 7 files, 54 tests.

Untested: the real `nomic-embed-text` model, behaviour under concurrent clients, large tables.

## E — Evaluations

10 questions in `evals/business-evals.xml`. Each answer was checked two ways: (1) the SELECT
in `evals/answer-key.tsv`, run as ygg_read in a read-only transaction, returns exactly that answer;
(2) the same answer was computed through the tools (`business_list_items` paging and filters,
`business_summarize_items` grouping). Ties were checked: each top-1 answer beats the runner-up
by a clear margin. Tools exercised: list_items (Q1, 2, 5, 6, 7, 8), summarize_items (Q3, 4, 9, 10),
get_item (optional for Q7). Not exercised by evals: search (needs a real embedder), and leads and
exit profiles (empty in scratch).
