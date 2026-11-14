# runner/ — the task belt

The runner takes a task ("make this file", "fix this script"), has a **local** AI model do the
work **inside a sealed container**, checks the work, and then **stops and waits for the owner**.
Nothing an AI produces counts as finished until a person says yes at a terminal. Every step
leaves a receipt in `data/`'s tamper-evident chain.

## What's here

| Path | What it is |
|---|---|
| `conveyor/` | The task belt itself, copied with its git history from `~/conveyor-json` (branch `json-tasks`, commit `bb02310`, which sits on top of `~/conveyor` `ff4a77d`). Trays (`plan/ queue/ running/ verify/ human/ done/ failed/`), the runner (`conveyor-run.sh`), the JSON task schema (`task-schema/`), the planner / critic / executor / verifier prompts (`*-preamble.md`), the local model agent (`conveyor-local-agent`), tests. Its own README explains the belt in depth. |
| `ragnarok/belt` | **The one command to use.** Runs the belt in the container, copies receipts into `data/`, and holds the person-only `approve` / `accept` / `reject`. |
| `ragnarok/Dockerfile` | The container ("the box") every leg runs in. |
| `ragnarok/model-door.py` | A tiny gate on the Mac that is the box's only way to a model. |
| `ragnarok/belt.env.example` | Settings you can change (copy to `belt.env`). |
| `scripts/test-throwaway.sh` | Proves all of it on a throwaway stack, then deletes it. |

## How a task moves

1. `./belt add "title" -m "what you want"` puts it on the belt. Add `--plan` to have it planned first.
2. `./belt run` works the belt. Inside the box:
   - with `--plan`, a **planner** model writes the task as JSON (schema-checked by code), and a
     **different critic** model reviews it. If the critic passes it, it goes to `human/` as
     **"Plan proposed"**. It does not start work.
   - a **driver** model does the work in `/work`, using only three tools (run a command, read a file,
     write a file). Then the task's own check commands run (they decide, not the model's claim).
   - a **verifier** (fresh context, told to find what's wrong) re-checks. A pass goes to `human/` as
     **"Result proposed"**. It does not go to `done/`.
3. `./belt status` lists what waits on you. `./belt show TASK` prints its whole history.
4. You decide, at a terminal: `./belt approve TASK` (plan or HUMAN step → back on the belt),
   `./belt accept TASK` (result → `done/`), or `./belt reject TASK "why"` (→ `failed/`). Each asks
   you to type `yes`, and refuses when it isn't run from a terminal (scripts, pipes, AI tools).

## The walls (checked by `./belt probe`)

- **Local models only.** The box has no internet at all. Its one way out is the "model door" on the
  Mac, which forwards to the alexus Ollama and allows only listing models and chatting with the
  three named models. It refuses everything else (pulling, deleting, Ollama's admin calls) and
  refuses to start if pointed at anything that isn't this Mac or the local network.
- **Cloud seats are switched off.** The belt can drive Claude, Codex, Gemini, Grok; the wrapper
  forces every seat to the local model and never passes any key into the box.
- **What the AI can touch:** only `runner/.work/` (seen as `/work`) and the trays. `done/` is
  mounted read-only, so only `./belt accept` can file anything as done. The belt's own code is
  read-only. No database login ever enters the box.
- Each run is limited to 2 CPUs and 2 GB of memory (`RUNNER_CPUS`).

## Receipts

After each run, `./belt` copies every new line of the belt's own log (`logs/receipts.jsonl`) into
`data/`'s `runner.runner_events` table, one row per leg. Each row gets a `write_log` receipt in the
hash chain (actor `runner:driver`, `runner:critic`, ...) and is marked **proposal**. Copying twice
adds nothing. A person's approve/accept/reject is written by the wrapper itself (never read from
the AI's log), with actor `human:<name>` and proposal = false, and only `data/`'s admin login can
write such a row (the AI's login can't). `./belt receipts` lists them; `./belt verify` checks the
chain.

Each row also has `model_reported` (since 2026-10-30): the model name(s) the model API put in its
answers during that leg (the response's `model` field, collected by `conveyor-local-agent` /
`conveyor-taskjson api` / a CLI stream's `message.model`), next to `model`, which is only what the belt
was configured to use. It is NULL for rows where no model ran (`runner`), for people's decisions, and
for every row copied before the change. The model door also logs `reported=<name>` for each answer in
`logs/model-door.log`, on the Mac, outside the box.

## Run it

```bash
cd ~/Developer/ragnarok/data && ./kit up          # the data layer (applies db/runner.sql)
cd ../runner/ragnarok
./belt build && ./belt doctor && ./belt probe
./belt add "hello" -m $'Create /work/hello.txt saying hi\n\n## Checklist\n- [ ] it says hi :: verify: grep -qx hi /work/hello.txt'
./belt run          # then: ./belt status, ./belt show ..., ./belt accept ...
```

Test everything on a throwaway stack (about 15 minutes, mostly the model thinking on alexus):
`runner/scripts/test-throwaway.sh`.

## What changed from the original belt (merged / dropped)

- **Merged:** all tracked code, prompts, schema, examples, tests and docs of `json-tasks @ bb02310`
  (with history). Never copied: the plaintext-password task file, `conveyor.env`, `logs/`, `queue/`
  and `attachments/` contents (none of them is tracked in git; the import came from git only).
- **Review gate (new, `CONVEYOR_REVIEW_GATE=1`, on in the box):** upstream sends a critic-passed
  plan straight to work and a verified result straight to `done/`. With the gate, both stop in
  `human/` for a person. Off, the belt behaves exactly as before (the upstream tests prove it).
  Tested by `conveyor/tests/review-gate.sh`.
- **Text tool calls (new, `CONVEYOR_LOCAL_TEXT_TOOLS=1`):** the local models on Ollama write tool
  calls as text instead of real tool calls, so they did nothing. The agent now reads such a call
  (only the three tools) and runs it, and trims a stray ``` after the final RESULT line.
- **Dropped / off:** cloud seats; the phone notifications, the dashboard, and the YGG/Airtable hooks
  (replaced by the bundled `standalone/` local files plus `data/`'s receipt chain).

## Honest limits

- The "person at a terminal" check stops scripts, pipes and AI tool calls. Someone with a full
  shell on the Mac can fake a terminal (the test does exactly that to play the person).
- Local models are slow on the alexus CPU: a simple task takes about 2 minutes; planning about
  5 minutes per planner call. Small critics nit-pick: in testing, `llama3.2:3b` sent a fine plan
  back twice and the belt stopped it in `human/` ("plan deadlock") instead of starting work.
- The runner writes its receipts with `data/`'s AI login directly (like fix-memory), not through
  the connector.
