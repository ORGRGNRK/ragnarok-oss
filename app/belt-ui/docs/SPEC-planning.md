# Planning first — spec (local Mac belt, 2026-10-26)

## Why
Cloud AI time is the scarce thing. Planning and reviewing a plan are short,
cheap jobs; writing the code is the long, expensive one. So: a cloud AI writes
the plan, a *different* cloud AI picks holes in it, and once they agree the
build itself can go to the driver seat — which can be the free local model
(Ollama) — with every step held to a check the computer runs.

## The trays a planned task moves through
    plan/ → queue/ → running/ → verify/ → done/
             exits along the way: human/ (needs you)   failed/ (dead end)

- **plan/** is new. Only tasks added with "plan it first" go there.
- While a planner or critic is working, the task sits in running/, as today.
- Everything after queue/ is the belt you already have.

## Seats (who does what) — set in the app or as environment variables
| Job | Variable | Default |
|---|---|---|
| Writes the plan | `CONVEYOR_PLANNER_SEAT` | claude |
| Reviews the plan | `CONVEYOR_CRITIC_SEAT` | grok (claude if the planner is grok) |
| Does the work | `CONVEYOR_DRIVER_SEAT` (existing) | claude |
| Final check | `CONVEYOR_VERIFIER_SEAT` (existing) | claude |
| Takes over one stuck step | `CONVEYOR_ESCALATE_SEAT` | unset = ask you |
| Local model name | `CONVEYOR_LOCAL_MODEL` (existing) | — |

Seats are the same five as today: claude, codex, gemini, grok, local.
Program paths come from the existing `CONVEYOR_CLAUDE/CODEX/GEMINI/GROK`.

## What a plan looks like
The planner answers with a checklist in the belt's existing format. Every step
is one small piece of work plus a shell command that proves it:

    ## Checklist
    - [ ] the report file exists :: verify: test -s "$CONVEYOR_OUTPUTS/report.csv"
    - [ ] it has 12 rows :: verify: wc -l < "$CONVEYOR_OUTPUTS/report.csv" :: expect: ^13$

The belt **rejects a plan by itself** (before the critic sees it) if any step
has no check, has an empty or do-nothing check (`true`, `:`), is a "HUMAN"
step, arrives already ticked, or if there are no steps at all. A rejected plan
uses up that round, and the reason is written into the task.

## The critic's rules
- It only lists problems (`PROBLEM: …` lines), or approves (`VERDICT: approved`).
  It never rewrites the plan.
- If it finds problems, the planner gets another go, with the critique in front of it.
- At most **2 rounds**. If there's still no approval, the task goes to human/ with
  both sides' notes. If the last plan was valid, it carries a "you accept
  this plan anyway" box. Approve it and the task is built on that plan.
- Approved → the plan becomes the task's live checklist and the task moves to queue/.

## The step loop (while building a planned task)
- After every work leg the belt runs every step's check (it already did this).
  Failures go back into the task file for the next leg.
- New: the belt counts failures **per step**. When one step has failed 3 times:
  - if `CONVEYOR_ESCALATE_SEAT` is set, the next leg (just one) goes to that seat,
    told which step is stuck. Then work goes back to the normal driver.
  - if that seat can't fix it either, or no escalate seat is set, the task goes
    to human/ with a "look at this stuck step" box. Approve it and the belt
    tries again with a fresh count.
- The existing 10-leg limit and the final verifier are unchanged.

## How to turn it on (off by default)
- Terminal: `./conveyor add "title" --plan -m "what you want"`
- App: tick **Plan it first** in the add form, and pick the planner and critic
  in AI providers. Both are greyed out when the app is pointed at Alexus.
- Tasks added without it behave exactly as before.

## What gets written down
- In the task file: "## Plan round N — planner (seat)" with the plan quoted,
  "## Plan round N — critic (seat)" with its problems or approval, then
  "## Plan approved" or "## Plan needs you", and notes for "step escalated" and "step stuck".
- One line per planner/critic run in logs/receipts.jsonl (plan-approved,
  plan-revise, plan-rejected, plan-deadlock), full transcripts in logs/.
- Asks for you go to logs/human-inbox.jsonl, the same as other human/ items.

## The local model (where the coding happens)
The `local` seat talks to an OpenAI-compatible server over HTTP. That can be LM Studio,
Ollama's `/v1`, llama.cpp's server, or vLLM. The server can be on any machine
on the network. The belt itself runs a small, built-in agent loop
(`conveyor-local-agent`) that gives the model three tools: run a command, read
a file, write a file.

| Setting | Default |
|---|---|
| `CONVEYOR_LOCAL_BASE_URL` | `http://127.0.0.1:1234/v1` |
| `CONVEYOR_LOCAL_MODEL` | the model name the server lists |
| `CONVEYOR_LOCAL_API_KEY` | optional. It is sent to the server only, never logged, and never passed to the commands the model runs |
| `CONVEYOR_LOCAL_API=anthropic` | the old route (Claude Code pointed at Ollama, `CONVEYOR_LOCAL_URL`) |

Before a local leg runs, the belt asks the server for `/models`. If the server
doesn't answer, or doesn't list the model, the run stops with a plain message.
If it fails partway through a leg, that counts as a seat crash: the leg is
refunded, the task goes back to queue/, and the belt waits before trying again.

**Intended setup.** The model runs on Alexus (GTX 1080, 8 GB). A 7B model at
4-bit fits entirely in that card's memory. The belt on the Mac points at it
over Tailscale:

    CONVEYOR_DRIVER_SEAT=local
    CONVEYOR_LOCAL_BASE_URL=http://alexus:<port>/v1
    CONVEYOR_LOCAL_MODEL=<model name>

The port is still to be decided. Checked read-only on 2026-10-26: Ollama on
Alexus already answers at `http://alexus:11434/v1`, and the Mac can
reach it. It lists `conveyor-general`, `qwen2.5:7b` and `qwen2.5-coder:7b`
among others. Nothing has run on it yet. Whether those models make proper tool
calls through the OpenAI API hasn't been tested. On 2026-10-21 qwen2.5-coder:7b
did not, through the Anthropic route.

## Porting to Alexus (planned, not done)
The timer belt runs as user `conveyor` from
`/srv/ragnarok/projects/src/ALEXUS/packages/conveyor` (conveyor.timer, every 5
minutes, `CONVEYOR_STANDALONE=1`, driver and verifier claude). That folder is
part of the ALEXUS git repo. Its group is `ragnarok`, and `grok` and
`conveyor` are both in that group, so **user `grok` can write there**. `grok`
also has sudo, which is needed for the service settings.

Its files are **not** the Mac's. Alexus's copies of conveyor-run.sh,
conveyor-check and the preambles differ from the Mac's, its conveyor-add has
no `--attach`, and it has no `conveyor` wrapper. So this is a merge, not a copy.

What would change there:
- `conveyor-run.sh`: the plan stage, per-step tries, `seat_check`, and the OpenAI local seat
- `conveyor-local-agent` (new), `standalone/planner-preamble.md` and `standalone/critic-preamble.md` (new)
- `conveyor-add` (`--plan`) and `conveyor-status` (the plan line)
- a `plan/` folder (group ragnarok, setgid like queue/), `.gitignore`, tests/plan.sh and tests/local-api.sh
- the systemd unit's `Environment=` lines; the Mac app's remote mode (so it can add to plan/)

Steps:
1. As `grok`: `git status` in ALEXUS, make a branch, and copy the package folder to a dated backup.
2. Merge the Mac changes into Alexus's versions, file by file. Commit on the branch.
3. Run tests/plan.sh and tests/local-api.sh there with the stub seats (no real AI).
4. Pause the timer (`sudo systemctl stop conveyor.timer`) while switching over.
   Add the settings with `sudo systemctl edit conveyor.service`:
   `CONVEYOR_PLANNER_SEAT`, `CONVEYOR_CRITIC_SEAT` (a seat the `conveyor` user is
   logged into; grok is the default), `CONVEYOR_LOCAL_BASE_URL=http://127.0.0.1:11434/v1`
   (same machine), `CONVEYOR_LOCAL_MODEL`, and, to build locally, `CONVEYOR_DRIVER_SEAT=local`.
5. `sudo systemctl daemon-reload`, start the timer, add one small `--plan` task, and watch it.
6. Undo: switch the folder back to the backup (or `git checkout` the old commit),
   remove the added settings, `daemon-reload`.

## Limits and non-goals
- **Built and tested on the belt on this Mac (~/conveyor) only.** Alexus's
  belt is unchanged until the port above is done, and the app doesn't offer
  planning for a remote belt yet.
- The local model is only as good as it is. The checks stop bad work getting
  through, but they don't make the model smarter.
- A check can only prove what it tests. A weak check is the critic's job to catch.
- No automatic re-planning in the middle of a build. A stuck step goes to one
  stronger seat, then to you.

## Test plan (fake AI scripts only, no real AI runs)
tests/plan.sh drives the real belt with stand-in AIs and checks:
1. the critic approves in round 1 → queue/
2. the critic objects, the planner revises, the critic approves → queue/
3. they never agree → human/ after 2 rounds, with both sides' notes, and approving it builds the plan
4. a plan with a step missing its check is rejected before the critic sees it
5. a step that fails 3 times → the escalate seat takes over (and with none set → human/)
6. the happy path: plan → build → verify → done/
plus "tasks added without --plan are unchanged". tests/local-api.sh runs the
local seat against a stand-in OpenAI server: no server, wrong model, a full
task to done/, the key never leaking, and a server error refunded. Then the existing tests run again:
tests/files.sh, tests/portable.sh, tests/grok-seat.sh and the app's checks/files-check.sh.
