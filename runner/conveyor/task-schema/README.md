# Conveyor task schema — DRAFT 0.1

On branch `json-tasks` this folder IS wired in: `conveyor-taskjson` uses it for
every task added with `--plan` (see ../SPEC-json-tasks.md). It started as a copy
of the draft schema; changes made here for the branch: a neutral `$id`, an
`operator` value for `provenance.source`, and `critic-verdict.schema.json`.
The text below is the original draft note, kept as written.

## What this is
Today a conveyor task is a **markdown file** that moves between lane folders
(`queue/ running/ verify/ human/ done/ failed/`). It has a `# title`, a few header
lines (`queued:`, `by:`, sometimes `finding-*:`), free prose, a `## Legs: N` counter,
and a `## Checklist` whose lines look like
`- [ ] <claim> :: verify: <command or HUMAN> [:: expect: <regex>]`.
`conveyor-check` runs those commands; that is the real "done" gate.

This folder adds a **JSON shape** for the same thing, small enough for a local model
to fill in reliably, so that code — not a model — can say "this task is well formed".

## The autonomous flow (planner -> schema check -> reviewer -> queue -> coder)
The owner's call (2026-10-28): planner tasks go straight onto the belt without waiting for
his approval. The point is autonomy, so agents don't need babysitting. The guardrails
are about keeping each job small and in scope, not about asking permission.

1. **Planner model writes the task.** It is called with `task.schema.json` as a hard
   output constraint, so it can only produce JSON with the right fields, types and
   lengths. It may set `status: "queue"` directly. `proposed` is still allowed, for a
   task someone wants held back for a look first.
2. **Code checks it.** `validate.py` checks the JSON against the schema plus the
   cross-field rules the grammar can't express:
   - at most one HUMAN check
   - at least one real test command
   - every created or edited file is inside `write_scope`
   - no `..` in paths
   - the number of files to change is within `limits`
   - no self-dependency
   - verify/expect are single lines with no ` :: `

   The schema itself pins `secrets: "none"` and the size limits. Exit 0 = valid,
   1 = invalid. No model is involved. An invalid task never reaches the belt.
3. **Reviewer model checks the sense.** A second model reads the valid task: does the
   plan make sense, is it small, does the test actually prove the goal? A pass sends
   it on; a fail sends it back to the planner.
4. **Queue.** The task is rendered (`validate.py task.json --render` prints the
   belt-style markdown) and dropped into `queue/` like any other task.
5. **Small local coder model does one job.** One goal, at most 6 short steps, at most
   5 files and a line budget. The acceptance checks become the `## Checklist`, so
   `conveyor-check` decides whether it worked, exactly as today.

`provenance` (`proposed_by`, `source`, `proposed_at`) is required and kept as an
audit record of who or what wrote each task. `approved_by` is optional (string or
null) and nothing checks it. The renderer prints it as an `approved-by:` header when set.

## Files
- `task.schema.json` — the schema (JSON Schema draft 2020-12, llama.cpp-friendly subset).
- `example-task.json` — one valid task (a unit test for `dupes.norm` in ragnarok-pipe).
- `broken-schema-example.json`, `broken-rules-example.json` — deliberately invalid.
- `validate.py` — `python3 validate.py <task.json> [--minimal] [--render]`.
  Uses `jsonschema` from `./.venv` if run with `.venv/bin/python`, else a built-in checker.
- `tools/json_schema_to_grammar.py` — llama.cpp's converter (copied from GitHub, from just
  before it was removed from the repo in March 2026); `tools/task.gbnf` is its output for
  this schema, proof the schema converts to a grammar.

## Turning on schema-constrained output in llama-server (docs only)
No server change is needed; it's per request. On the OpenAI-style endpoint:

```
POST http://<llama-server>/v1/chat/completions
{
  "messages": [ {"role": "system", "content": "You plan ONE small conveyor task..."},
                {"role": "user",   "content": "<the ask>"} ],
  "temperature": 0.2,
  "response_format": {
    "type": "json_schema",
    "json_schema": { "name": "conveyor_task", "schema": <contents of task.schema.json> }
  }
}
```
llama-server reads `response_format.json_schema.schema` for `type: "json_schema"`
(checked in `tools/server/server-common.cpp`). It also accepts
`{"type": "json_object", "schema": {...}}`. On the native `/completion` endpoint the
field is `"json_schema": {...}`. Server-wide alternatives: start flag
`--json-schema-file task.schema.json`, or `--grammar-file tools/task.gbnf`.

Notes on the constraint:
- The grammar forces **shape**, not **truth**: a model can still write a wrong command.
  That is what validate.py, the reviewer and `conveyor-check` are for.
- When a string has a `pattern`, llama.cpp uses the pattern and ignores min/maxLength
  for that field; validate.py still enforces both.
- Keep the schema free of `contains`, `not`, `if/then`, lookaheads; the converter
  doesn't support them. Cross-field rules live in `validate.py` instead.
- Put the schema text (or a short field list) in the prompt as well; grammar-only
  constraint without explanation tends to produce terse, low-quality values.
