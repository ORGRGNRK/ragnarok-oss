<!-- Maintainers only. If you are helping someone install or use conveyor, skip to "Instructions for AI assistants" below. -->
## Current state / Next step (maintainers)
- Mac working copy of the belt, first committed 2026-10-26 (76c4f36). Tray contents, logs, attachments and outputs are not tracked (see .gitignore).
- This copy has the `--plan` planning step (SPEC-planning.md), `--attach` file inputs, and a Grok Build (`grok`) seat.
- The Grok seat is stub-tested only (`tests/grok-seat.sh` with a fake `grok`); it has never run against the real AI.
- 2026-10-26: a seat that reports BLOCKED while the only open checklist steps are `HUMAN` steps (and every command step passes) now parks in human/ (verdict `blocked-human-wait`), so the app's Approve button works on it. Any other BLOCKED is still a dead end in failed/, which has no button in the app. The hand-tick forgery guard still runs first. Regression test: `tests/blocked-human.sh` (24/24, fake seats only).
- `tests/portable.sh` scans this working copy, so it fails here while real tasks or logs sit in the trays; it passes 13/13 on a clean clone.
- Next step: one real end-to-end run of a planned task. Only after that works, port these belt changes to the release repo.

**Handoff rule:** before handing off or ending a session, commit, push if a remote exists, and update the block above.

---

# Instructions for AI assistants

You are helping a person install and use **conveyor**: a task queue that hands
work to an AI CLI and only files it as done when the work is proven. Follow
these steps. Keep the person informed in plain language and don't make them do
anything you can do yourself.

## 1. Install

1. Clone into the person's home folder unless they name another place:
   `git clone https://github.com/ORGRGNRK/conveyor ~/conveyor && cd ~/conveyor`
2. Run `./conveyor setup`. It installs dependencies (Homebrew on macOS, the
   system package manager on Linux) and then runs `./conveyor doctor`.
   - On macOS without Homebrew, tell the person to install it from https://brew.sh
     (it needs their password), then run setup again.
   - On Linux it uses `sudo`. If you can't enter a password, give them the exact
     command to run.
3. `./conveyor doctor` must end with `Ready.` If a line says `FIX`, do what it
   says and run doctor again.
4. Tell the person it's installed, which AI seat it will use (default
   `claude`), and that nothing runs on a schedule.

## 2. Turning a request into a task

When the person asks you to "use the conveyor" or "put X on the conveyor":

1. Write a short task body: one `Want:` line in their words, then any facts the
   worker needs (paths, links, limits), then a checklist.
2. **Every checklist item needs a proof command:**
   ```
   - [ ] <what must be true> :: verify: <shell command that exits 0 only when it is true>
   ```
   - Prove results with files: have the task write its output to a file, then
     check the file (`test -s`, `grep -q`, `jq -e`, a count with `test ... -ge N`).
   - Add `:: expect: <text>` when the command's output must contain something.
   - Use `:: verify: HUMAN` for anything only the person can judge (taste,
     approval, "is this the right one?"). Only the person can tick these.
   - Make the checks strict enough that fake or empty work fails them.
   - If you can't say how it would be proven, leave the checklist out. The
     conveyor's spec step will write one and wait for the person's approval.
3. Add rules where needed: "read-only", "don't buy anything", "don't send
   messages", "never invent data; give a URL for every fact".
4. Queue it:
   ```bash
   ./conveyor add "short title" <<'EOF'
   Want: ...

   ## Checklist
   - [ ] ... :: verify: ...
   EOF
   ```

5. Big or fuzzy jobs: add `--plan` to have a planner AI write the checklist
   and a second AI review it before anything is built (see SPEC-planning.md).
   The task waits in `plan/` until they agree, or lands in `human/` if they don't.
   With `--plan`, leave the checklist out: the plan replaces it.
6. Files: add `--attach FILE` (repeatable, any file type, 100 MB each) to give
   the worker input files; they are copied to `attachments/<task-id>/` and
   listed in the task. Every task gets `outputs/<task-id>/` for its results;
   checklist commands can use `"$CONVEYOR_OUTPUTS/<file>"`.

**Ask first** before queuing anything that spends money, deletes things, sends
messages, or changes accounts. The worker seats run with full permissions.

## 3. Running it

Run `./conveyor run`. It works one leg at a time (build, check, second-AI
review) until the queue is empty, a task is waiting on the person, or nothing
moves. Each leg can take a few minutes.

## 4. Reporting back

- Finished tasks are in `done/`. Read the task file and any output files it
  made, and give the person the actual result, not just "it's done".
- A task in `human/` is waiting on them. Show them the step and ask. To record
  their answer, tick that `verify: HUMAN` line (`- [x]`) **only when they've
  actually said yes**, then move the file to `queue/` and run again.
- A planned task in `human/` with `## Plan needs you`: the planner and critic
  did not agree. Show the person both sides' notes. If they accept the plan,
  tick its HUMAN box and move it to `queue/`; if they want to re-plan, edit the
  request at the top and move it to `plan/`.
- A task in `failed/` has a `## Dead End` section saying why it stopped. Explain
  it plainly. To retry, move it back to `queue/` and set `## Legs:` to `0`.
- `./conveyor status` shows everything at a glance.

## Rules for you

- Never tick a checklist box yourself, except a `verify: HUMAN` box after the
  person's real yes. The conveyor's whole point is that proof comes from
  commands, not from a model saying so.
- Never edit task files in `running/` or `verify/`.
- Don't run the belt on a timer unless the person asks (`install.sh`, Linux only).
