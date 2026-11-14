# fix-memory (inside Ragnarok: `brain/fix-memory/`)

> **Ragnarok copy.** Imported from `~/Developer/fix-memory` (main @ `fe47a7e`, history kept as a
> subtree merge; the original folder is untouched). Changed for Ragnarok: it no longer has its own
> Postgres or its own `receipts` table. Its tables live in the data layer's ONE Postgres
> (`data/db/brain.sql`) and every change gets a receipt in data/'s hash-chained `write_log`.
> See `brain/README.md` for the plain-English overview. The demo logs in `docs/` are from the
> original (before this change).

A build-time self-healing test loop. Code is meant to break **while it is being made**, not
when someone uses it. `fixloop` runs your tests in a throwaway container. When they fail, it
looks up similar past fixes, asks a **local** coding model for a fix, and tries again. When a
fix works, it saves what went wrong and what fixed it, so the next identical failure can be
healed from memory.

Everything runs locally: Ollama (on this Mac or the LAN box; other hosts are refused), the data
layer's Postgres + pgvector, and Docker/OrbStack for tests. No cloud AI APIs are called anywhere in this code.

## What it actually does (one `fixloop run`)

1. Copies the project into `.work/<name>-<timestamp>/`. The original folder is only touched at
   the very end, and only if the tests pass.
2. **Test**: runs the test command in a fresh container
   (`docker run --rm --network none --memory 1g --cpus 2`, image `ragnarok-brain-runner:local` =
   python:3.12-slim + pytest). Exit code 0 = pass.
3. **On failure**:
   - Cleans up the output (paths, timings, and addresses are stripped) and pulls out an *error
     signature* (pytest `E` lines, `FAILED`/`ERROR` lines, exception lines).
   - Embeds the signature with `nomic-embed-text` and fetches the **top 3** past fixes by cosine
     similarity from Postgres/pgvector (`brain.fix_vectors`). All 3 are printed.
   - **Memory gate**: only fixes with similarity ≥ `FIXLOOP_MIN_SIMILARITY` (default 0.97) are
     used. In testing, `nomic-embed-text` scored *different* bugs from the same test file at
     0.89–0.95, and small models copied those wrong fixes, so lower matches are only logged.
   - **Replay**: when a fix passes the gate, its stored diff is applied directly with `patch`
     and tested. If that passes, no model call is made.
   - **Model candidates**: otherwise the local coder model gets the source files, the failing
     output, any gated past fixes, and notes on earlier failed tries. It is asked for
     `FIXLOOP_CANDIDATES` (default 3) candidate edits at different temperatures. Each candidate
     is tested in its own throwaway container, and the best one is kept (a pass beats fewer
     failures, which beats an import/syntax error). An edit that makes things worse is reverted.
   - Safety rules for edits: only `.py` files inside the project, never test files
     (`test_*.py`, `*_test.py`, `conftest.py`, `tests/`). If a model returns only the
     function it changed, that function is spliced in and the rest of the file is kept.
4. Repeats up to `--max-tries` test runs (default `FIXLOOP_MAX_TRIES` = 5).
5. **On a pass after a failure**:
   - New fix: the first error, the model's one-line cause, and the unified diff are saved to
     `brain.brain_fixes` (the database writes its receipt).
   - Healed by replaying a stored fix: no duplicate fix is added. A `fix_reused` row that
     points to the stored fix is added to `brain.brain_fix_events` instead (also receipted).
   - The healed files are copied back into the project (skip this with `--no-write-back`).
6. **On giving up**: the project is left unchanged. The last attempt and every prompt and model
   reply (`.fixloop-try*-*.txt`) stay in the `.work/` copy for inspection.

The last line of output is `[fixloop] summary {...json...}`. The exit code is 0 if the tests
pass in the end and 1 if the loop gave up.

## Receipts (change log)

There is ONE receipt chain per project: the data layer's append-only `write_log`. fixloop never
writes receipts itself. Adding a row to `brain.brain_fixes` (a learned fix) or
`brain.brain_fix_events` (`fix_reused`, `reembed`) fires the database trigger that writes the
receipt in the same transaction: actor (`fixloop`, or the MCP caller), session (one id per run),
a short note (why), the **full** new row (error text, cause, diff), and
`hash = sha256(prev_hash + "\n" + row-as-json)`. Nobody can edit or delete the log (triggers
refuse it), and the AI's login can only add fixes, never change or delete them.

`fixloop verify` runs data/'s `kit_verify()`, which recomputes the write_log and access_log
chains (same as `./kit verify`). Tampering is *detectable*, not impossible: the database admin
could rewrite a whole chain; `./kit anchor` (in data/) is how you notice that.

Search vectors (`brain.fix_vectors`) are derived from the error text and can be rebuilt with
`fixloop reembed`, so they are not receipted (as before: embeddings were never in a receipt).

Changed from the original: the old separate `receipts` table and `fixloop/schema.sql` are gone
(schema is `data/db/brain.sql`), and `scripts/tamper_test.py` was dropped (it edited the old table
inside a transaction; data/'s own test suite already proves `kit_verify` catches tampering).

## Setup (once)

```zsh
cd ~/Developer/ragnarok/data && ./kit up      # the one Postgres (pgvector) + brain tables
cd ../brain/fix-memory && ./scripts/setup.sh  # runner image, Python env, fixloop doctor
```

fixloop reads the database settings from `ragnarok/data/.env` (Postgres port, database, and the
AI's read/write login), so there is nothing to configure here. An optional `.env` in this folder
can set the `FIXLOOP_*` model settings (see `.env.example`).

## Commands

```zsh
cd ~/Developer/ragnarok/brain/fix-memory
uv run fixloop doctor                                   # models present? DB up? runner image?
uv run fixloop run <project_dir> --test 'pytest -q'     # the loop
uv run fixloop run <dir> --test 'pytest -q' --max-tries 3 --no-write-back
uv run fixloop run <dir> --test 'pytest -q' --no-memory # A/B: no retrieval
uv run fixloop search "FAILED test_x.py::test_y - assert 1 == 2"
uv run fixloop receipts --limit 10
uv run fixloop verify                                   # kit_verify(): data/'s receipt chains
uv run fixloop stats
uv run fixloop seed-demo                                # seed from the demo's real failures
uv run fixloop reembed                                  # re-embed all fixes (after model change)
./scripts/demo.sh                                       # full demo (exit 0 = healed, reused, verified)
../scripts/test-throwaway.sh                            # everything above on a throwaway stack
```

The test command runs **inside the container with no network**. The default image only has
Python 3.12 + pytest. A project that needs other packages needs its own runner image
(`--image` or `FIXLOOP_RUNNER_IMAGE`) with those packages preinstalled.

## Configuration (`.env` or environment)

| Variable | Default | Meaning |
|---|---|---|
| `FIXLOOP_OLLAMA_HOST` | `http://127.0.0.1:11434` (`.env.example`: LAN box `http://alexus.local:11434`) | Ollama server; must be local/LAN |
| `FIXLOOP_CODER_MODEL` | `qwen2.5-coder:7b` (was `qwen2.5-coder:3b` until 2026-10-30; set it back here if the 7B is too slow) | model that writes fixes |
| `FIXLOOP_EMBED_MODEL` | `nomic-embed-text` | 768-dim embeddings (schema is `vector(768)`) |
| `FIXLOOP_MAX_TRIES` | 5 | total test runs per `fixloop run` |
| `FIXLOOP_CANDIDATES` | 3 | model candidates sampled and tested per try |
| `FIXLOOP_MIN_SIMILARITY` | 0.97 | memory gate for replay / showing fixes to the model |
| `FIXLOOP_RUNNER_IMAGE` | `ragnarok-brain-runner:local` | test container image |
| `FIXLOOP_TEST_TIMEOUT` | 300 | seconds per test run |
| `FIXLOOP_PG_*` | from `ragnarok/data/.env` (`POSTGRES_PORT`, `POSTGRES_DB`, `MCP_DB_USER`/`MCP_DB_PASSWORD`) | override only if needed |
| `FIXLOOP_ACTOR` | `fixloop` | name written on receipts |

## MCP tools: now in the connector

The 4 MCP tools (`brain_search_fixes`, `brain_record_fix`, `brain_list_receipts`,
`brain_verify_receipts`) are served by Ragnarok's one MCP server, **`ragnarok/connector`**
(`src/brain.ts`), since 2026-10-30. Same names, arguments and search (same embedding call and error
signature, so fixes stored by `fixloop` and by the tools find each other). Receipts follow the
connector's rules: `actor` required, one `access_log` row per call (refusals too), and
`brain_record_fix` needs the connector's write key. Connect as described in `../../connector/README.md`
(HTTP on `127.0.0.1:8891/mcp`, or `../../data/kit mcp-stdio`).

The old Python stdio server `fixloop-mcp` is retired: `fixloop/mcp_server.py` is now a stub that
prints where the tools went and exits; its code is in git history
(`git log --follow -- brain/fix-memory/fixloop/mcp_server.py`). Remove any saved client config that
runs `uv run fixloop-mcp`. The `mcp` Python dependency and `scripts/mcp_smoke.py` were removed; the
smoke test is now `connector/test/brain-smoke.ts`, run by `brain/scripts/test-throwaway.sh`.

## Demo results (original repo, before the Ragnarok move; 2026-10-30, qwen2.5-coder:3b + nomic-embed-text on the LAN box)

The demo `examples/demo_median` has a deliberate bug: `median()` doesn't sort. Two of its 4
tests fail. Memory was seeded with 3 **different** real bugs from the same demo (`mean()`
off-by-one, even-length median taking one middle value, `//` instead of `/`). Each one was
created, actually run in the container, and saved with the real failing output and real diff.
Full logs are in `docs/`.

- **Healing run** (`docs/demo-heal.log`, run 2): failed; the top-3 seeds matched at 0.95/0.93/0.89
  (below the gate). Healed on try 5 of 5 after several rounds of model candidates; saved as
  fix #4 with a receipt. (Run 1 in the same log gave up after 5 tries: the 3B model kept
  returning the file unchanged.)
- **Same bug again** (`docs/demo-reuse.log`): memory hit 0.980 on fix #4 → replayed → tests pass
  on try 2 with no model call; `fix_reused` receipt written.
- `fixloop verify`: chain OK (6 receipts).

Honest notes from the demo:
- Small local models are the weak link. `llama3.2:3b` and `qwen2.5vl:3b` never fixed the bug.
  `qwen2.5-coder:3b` often echoes the file unchanged and needed several tries. A bigger coder
  model (e.g. `qwen2.5-coder:7b`, about 4.7 GB) would likely do better, but it is not
  installed. **Update 2026-10-30 (Ragnarok):** `qwen2.5-coder:7b` is now on the alexus box and is
  the default; it healed this demo without memory in 5 of 5 throwaway runs (each on try 2),
  versus 3 of 13 for the 3B. See `../README.md`.
- The learned fix (`values.sort()` in both branches) passes the tests but sorts the caller's
  list in place. The tests don't check for that, so neither does the loop. **The loop is only
  as strict as your tests.**

## Hooking into the conveyor (not wired yet)

Nothing in `~/conveyor` was changed. The intended hook: wherever the conveyor's retry step
re-runs a failed coding task, call

```zsh
cd ~/Developer/ragnarok/brain/fix-memory && uv run fixloop run <task_project_dir> --test '<task test cmd>'
```

before (or instead of) a blind retry. Use the exit code (0 = tests pass, 1 = gave up) and the
final `[fixloop] summary` JSON line (`healed`, `tries`, `memory_hit`, `reused_fix_id`,
`recorded.receipt_hash`) to decide whether to advance the task or escalate it to a human or a
bigger model. Agents can also use the connector's `brain_search_fixes` /
`brain_record_fix` tools directly.

## Layout

```
fixloop/       cli.py loop.py sandbox.py ollama.py db.py receipts.py seed_demo.py mcp_server.py (deprecated stub) config.py
               (tables: ../../data/db/brain.sql)
runner/        Dockerfile for the throwaway test container
examples/      demo_median (deliberately broken; demo.sh works on copies)
scripts/       setup.sh demo.sh
docs/          demo logs
```
