# JSON tasks (branch json-tasks)

`./conveyor add "title" --plan -m "what you want"` now plans the task as JSON.

## The flow, one leg per `conveyor-run.sh` call (unchanged belt rhythm)

1. **Planner** (`CONVEYOR_PLANNER_SEAT`) gets `planner-json-preamble.md` and the
   task, and answers with ONE task object. On `claude` and `grok` the schema is
   also passed as `--json-schema` (structured output); on the `api` seat it goes
   in `response_format`. Every other seat (or `CONVEYOR_JSON_NATIVE_SCHEMA=0`)
   gets the schema in the prompt and the answer is pulled out of the reply
   (structured output, else the last ```json block, else the last JSON object).
   A CLI that refuses `--json-schema` is asked again once without it.
2. **Code checks it** (`conveyor-taskjson`): the schema, `validate.py`'s rules
   (inside `write_scope`, no `..`, file-count limit, at least one command check),
   and this belt's rules: no HUMAN checks (switch: `CONVEYOR_JSON_ALLOW_HUMAN=1`),
   no do-nothing checks, no credential-shaped text, no reading `.env`, keys,
   keychains or the environment (`secrets: none`), and optionally the root must be
   under `CONVEYOR_JSON_ALLOWED_ROOTS`. The belt itself fills in `status`
   (always `queue`) and `provenance`, so a model cannot hold a task back or
   fail on a timestamp.
   Invalid: the errors go back to the planner, up to
   `CONVEYOR_PLAN_JSON_RETRIES` (default 2) more times in the same round. Still
   invalid: the round is recorded as rejected and the next run starts a new one.
3. **Critic** (`CONVEYOR_CRITIC_SEAT`) gets `critic-json-preamble.md` and the task
   JSON, and answers `{"verdict":"pass","issues":[]}` or a list of issues
   (`task-schema/critic-verdict.schema.json`).
4. **Pass**: the task is rendered into the ordinary task file (goal, files, steps,
   rules, and a `## Checklist` of `- [ ] claim :: verify: cd ROOT && command`)
   and moved to `queue/`. **No human approval.** Issues: they are written into the
   task and the planner revises next round. After `CONVEYOR_PLAN_ROUNDS` (2)
   rounds without a pass, the task goes to `human/` with an "accept anyway" box:
   that is a disagreement fallback, not an approval step.
5. **Coder** (`CONVEYOR_DRIVER_SEAT`, e.g. `local`) builds it like any task;
   `conveyor-check` runs the task's own test commands, then the verifier seat.

**Scope and size guardrail.** When the task's root is a git repository, the
render records what was already changed there and adds one more checklist line,
`conveyor-taskjson scope-check`, which fails when a file outside `write_scope`
changed or the file/line limits were passed. (Caveat: another change in the
same repository between planning and the check also counts.) When the root is
not a git repository the task says so and only its own checks run.

The task JSON is kept at `logs/<task>.task.json`, the critic's verdict at
`logs/<task>.verdict.json`, every attempt's transcript beside them.

**Old tasks.** Only tasks with the header line `plan-format: json` (written by
`conveyor add --plan`) take this path. Tasks already in `plan/` without it, and
every ordinary task with a checklist, run exactly as before.

## Using any provider

- `claude`, `codex`, `gemini`, `grok`: the CLIs, found on PATH or `CONVEYOR_<NAME>`.
- `api`: any OpenAI-compatible chat-completions server, for planner or critic:
  `CONVEYOR_API_BASE_URL`, `CONVEYOR_API_MODEL`, `CONVEYOR_API_KEY_ENV` (the
  *name* of the variable holding the key), `CONVEYOR_API_RESPONSE_FORMAT`
  (`json_schema` | `json_object` | `none`). Per role: `CONVEYOR_PLANNER_API_*`,
  `CONVEYOR_CRITIC_API_*`. It has no tools, so it cannot read the repository;
  it plans from the task text alone.
- `local`: the coder on your own model server (`CONVEYOR_LOCAL_*`).

All of these can live in `conveyor.env` (see `conveyor.env.example`), which git
ignores. `./conveyor doctor` reports the plan format and checks the validator.

## Tests (no model is called)

    python3 tests/test_taskjson.py   # schema, rules, secrets, extraction, render, scope, api (stand-in server)
    bash tests/json-tasks.sh         # the whole leg with stub seats, plan -> done
