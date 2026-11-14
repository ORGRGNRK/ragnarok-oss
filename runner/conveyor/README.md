# conveyor

**An AI to-do list that only marks things done when they're actually done.**

You drop in a task with a checklist. An AI does the work. Then the conveyor
checks every item on the checklist *itself*, and a second AI with fresh eyes
tries to prove the work wrong. Only work that survives both gets marked done.

The AI saying "done!" counts for nothing. The proof is what counts.

---

## Quick start (the easy way)

You need an AI coding assistant that can run commands on your computer:
**Claude Code**, **Codex CLI**, or **Gemini CLI**. Open it and paste:

> Install the conveyor from https://github.com/ORGRGNRK/conveyor and set it up for me.

It reads `AGENTS.md` in this repo, installs what's missing, and tells you when
it's ready. Then just ask for things:

> Use the conveyor to find the three cheapest flights from LAX to Denver next
> Friday and save them to a file.

> Put this on the conveyor: check every link on my website and list the broken ones.

Your AI writes the task and its checklist, runs it on the conveyor, and tells
you the result, including if it got stuck and why.

---

## What makes it different

- **Proof, not claims.** Every checklist item has a command that proves it. The
  conveyor runs those commands itself. If they don't pass, the task goes back
  with the reasons attached.
- **A second opinion that's trying to say no.** A fresh AI seat with no memory
  of the first one reviews the work and tries to break it.
- **It knows when to stop.** A task gets more tries only while it keeps making
  progress. If it stalls, it stops and writes down exactly what went wrong.
  Nothing quietly fails.
- **It asks when it isn't sure.** A task with no checklist gets a plan written
  first, and waits for your yes before any real work happens.
- **Some steps are only yours.** A checklist item marked `verify: HUMAN` can only
  be ticked by you. The AI can't tick it for you.

## Why this exists

Every AI agent has the same hole: the model says it succeeded, and everything
after it believes it. The reply is not evidence.

This conveyor once caught an AI session ticking two checklist boxes reserved for
a human. It had checked the facts, decided they were true, and announced it was
skipping the gate. The second seat, with none of that context, read the command
log and failed the build anyway:

> "The BUILD is sound. What I am failing is the LOOP."

Nothing else would have noticed. The checklist would have read all-green.

---

## Doing it by hand

```bash
git clone https://github.com/ORGRGNRK/conveyor && cd conveyor
./conveyor setup        # installs anything missing (Homebrew on Mac, apt/dnf on Linux)
./conveyor doctor       # checks everything is ready and says what to fix
```

Add a task:

```bash
./conveyor add "Count the TODOs" <<'EOF'
Want: count the TODO comments in ~/myproject and write the number to ~/todo-count.txt

## Checklist
- [ ] the count file exists :: verify: test -s ~/todo-count.txt
- [ ] it holds a number :: verify: grep -qE '^[0-9]+$' ~/todo-count.txt
EOF
```

Run it:

```bash
./conveyor run          # works through the queue until it's empty or stuck
./conveyor status       # what's queued, running, done, failed, or waiting on you
```

### The task format

A task is a markdown file. The checklist is the contract:

```
- [ ] what must be true :: verify: <shell command that exits 0 when it is>
- [ ] something only you can judge :: verify: HUMAN
- [ ] output must say a thing :: verify: <command> :: expect: <text it must print>
```

Leave the checklist out and the conveyor writes one for you first, then waits
for your approval.

### Where things go

| Folder | Means |
|---|---|
| `plan/` | being planned (only tasks added with `--plan`) |
| `queue/` | waiting its turn |
| `running/` | an AI is on it now |
| `verify/` | built; the second AI is checking it |
| `human/` | waiting on you |
| `done/` | proven done |
| `failed/` | stopped, with the full story of why written into the file |
| `attachments/<task-id>/` | input files you attached (copies; the AI reads them, never changes them) |
| `outputs/<task-id>/` | what the task produced |

Attach files of any kind with `--attach` (repeat it for more; 100 MB per file,
change with `CONVEYOR_ATTACH_MAX_MB`):

```bash
./conveyor add "Summarize the report" --attach ~/Downloads/report.pdf -m 'Want: a one-page summary in summary.md

## Checklist
- [ ] the summary exists :: verify: test -s "$CONVEYOR_OUTPUTS/summary.md"'
```

### Plan it first (optional)

`./conveyor add "title" --plan -m "what you want"` sends the task to `plan/`
first. One AI (the planner, `CONVEYOR_PLANNER_SEAT`, default `claude`) writes
a list of small steps, each with a check command. A different AI (the critic,
`CONVEYOR_CRITIC_SEAT`, default `grok`) only lists problems or approves. Two
rounds at most; if they still disagree, it waits for you in `human/`. An
approved plan goes to `queue/` and is built as usual, so the builder can be a
cheaper or local model.

By default the planner writes the task as one JSON object (the shape is
`task-schema/task.schema.json`), code checks it, the critic answers with a JSON
verdict, and a task the critic passes goes straight to `queue/`: no approval
step. The old checklist planner is still there: `--plan-format markdown` or
`CONVEYOR_PLAN_FORMAT=markdown`. Details: [SPEC-json-tasks.md](SPEC-json-tasks.md).
Settings for your own setup (seats, model servers, keys) go in `conveyor.env`;
see `conveyor.env.example`. A step that fails its check 3 times goes, for one leg,
to `CONVEYOR_ESCALATE_SEAT` if set, otherwise to you. Full details:
[SPEC-planning.md](SPEC-planning.md).

Every task file keeps its whole history: each attempt, each verdict, each
reason. A failed task tells you exactly where it got stuck.

### Choosing the AI

The default seat is `claude`. Pick another with:

```bash
CONVEYOR_DRIVER_SEAT=codex CONVEYOR_VERIFIER_SEAT=claude ./conveyor run
```

Seats: `claude`, `codex`, `gemini`, `grok` (xAI's Grok Build), or `local`.
Small local models tend to skip the work and claim success. The conveyor
catches that, but they rarely get anything done unless the steps are small,
which is what `--plan` is for.

The `local` seat talks to any OpenAI-compatible server (LM Studio, Ollama's
`/v1`, llama.cpp server, vLLM), on this computer or another one on your network:

```bash
CONVEYOR_DRIVER_SEAT=local \
CONVEYOR_LOCAL_BASE_URL=http://192.168.1.10:1234/v1 \
CONVEYOR_LOCAL_MODEL=qwen2.5-coder-7b-instruct \
./conveyor run
```

If the server wants a key, also set `CONVEYOR_LOCAL_API_KEY` (it is sent to
the server only, never written to a log or shown to the model's commands).

The default URL is `http://127.0.0.1:1234/v1`. The model gets three tools
(run a command, read a file, write a file) through `conveyor-local-agent`.
The older path, Claude Code pointed at Ollama's Anthropic API, is still there
with `CONVEYOR_LOCAL_API=anthropic` (and `CONVEYOR_LOCAL_URL`).

## Requirements

- macOS or Linux (Windows: use WSL)
- One logged-in AI CLI: `claude`, `codex`, `gemini`, or `grok`
- `bash` 4+, `jq`, `curl`, `flock`, `python3`, GNU coreutils.
  `./conveyor setup` installs these for you.

It uses your AI subscription or API key through that CLI. Nothing else is sent anywhere.

## Safety

- The AI seats run with permission to act on your machine without asking.
  That's how they get work done unattended. Only queue tasks you'd be
  comfortable letting an assistant do by itself.
- Nothing runs on a schedule unless you turn it on (`install.sh` on Linux).
- Every result is checked by commands you can read in the task file.

## License

Free for personal and noncommercial use under the PolyForm Noncommercial License 1.0.0, see `LICENSE`. Any commercial use, including use by or for a business, needs a paid license: contact origin@rgnrk.co.
