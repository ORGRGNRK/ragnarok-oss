# Ragnarok Doctor

A per-user launchd daemon on the Mac watches **new** records in
`~/.ragnarok/ragnarok-app-errors.jsonl`. It does not watch every macOS app, server
service, crash report or uninstrumented exception. It does not run on Alexus.

It re-scrubs incoming rows through the installed Ragnarok executable before
storing or sending evidence to an AI. Prompts and raw AI stderr are not logged.
Structured model results and build/test output are scrubbed before storage.
Private state/config/artifacts live under `~/.ragnarok/doctor` (0700 directory,
0600 files). Incident records only accept a small allowlist of diagnostic fields.

## Severity routing

| Severity | Source policy | Worker |
| --- | --- | --- |
| Critical | Producer's explicit critical severity; fault level; uncaught-exception/auth/gate/security areas | Read-only diagnosis, repair, fresh read-only review before integration |
| High | Explicit high; workspace snapshot/backup, agent-runner or shell-setup area | Diagnosis and repair |
| Medium | Explicit medium or other error-level rows | Diagnosis and repair |
| Low | Explicit low or warning-level rows | Diagnosis and repair |
| Unverified | Missing/invalid severity and no recognized level/operation | Retained for inspection; no automatic repair |

## Which AI does the work

Each route has an ordered `agents` list. The default is `grok`, then `claude`, then
`codex`. Codex is the third and last fallback, not the first choice. The first agent
does every phase. The next one runs only when the one before it crashed, timed out or
gave no usable answer; an agent that failed is not asked again in that repair. A check
that refuses a change (protected file, outside edit, read-only call that edited) never
switches agents. Before the next agent diagnoses or repairs, the staging copy is reset
to the original commit so it does not inherit a half-made change. Every try counts
against the hourly call limit. The commit author names the agent that made the repair,
and branches are `doctor/<incident>-<attempt>`. An older config with a single
`agent` still works and uses only that agent. `model`/`review_model` as a string apply
to the first agent only; use `{"codex": "name"}` to set one per agent.

Only Codex has an OS sandbox here. Claude's read-only phases are limited to read tools;
Grok and Muse are told not to edit. For all of them the worker compares the worktree
before and after a read-only call and refuses the result if anything changed.

Severity is an operational policy, not a verified root cause. No keyword matching
on arbitrary error text can authorize a critical action. Current AppLog records
have error level and operation areas; it does not yet expose an explicit severity
parameter. A future structured producer may provide `severity` as above.

Operation policy can raise a producer's severity, and cannot be downgraded to low.
Critical incidents take priority among queued work. One worker runs at a time;
a critical arrival does not terminate an active repair. Duplicate fingerprints
share an incident/count, and can raise its severity. A critical escalation during
a repair requires independent review before integration. The review is a separate
fresh invocation through the same agent order. The critical review requirement
cannot be disabled by config. Other severities can also opt into second review.

## Repair lifecycle

1. Persist source cursor and incident in SQLite. Existing history is skipped on
   first startup. A missing source is recorded as missing; the first record after
   its creation is ingested. Partial lines wait for completion. The app's `.1`
   rotation is drained in bounded batches before switching to the current file.
   Missing rotated files or incomplete rotated tails are exposed as an Unverified
   `source_gap`; lost records cannot be reconstructed. Delivery is at least once: a crash between incident storage
   and cursor storage can increase a duplicate count, but does not create a new job.
2. Wait while the app folder has uncommitted edits or an installed build awaits
   restart. Other folders in the monorepo are not swept into a repair commit.
3. Start a worktree from the current commit. Read-only diagnosis must cite an
   existing source file and line. Transient/configuration failures and uncertain
   causes yield no code repair or `needs_attention`.
4. Repair in the staged folder (Codex uses its automatic approval review; Claude is
   limited to file tools; Grok and Muse run with approvals on). The agent is instructed not to deploy, read credentials
   or send messages. Its task embeds scrubbed incident data as untrusted evidence.
5. Require a new Python regression, run unchanged against original source (must
   fail) and repaired source (must pass). Tests run under sandbox-exec with network
   disabled and writes limited to staging/temp. Sandbox failures are not accepted
   as evidence that the original defect was reproduced. Run the existing build and
   selftest. Changes to the build/package, existing checks, frozen SelfTest, daemon
   or AGENTS.md are refused, as are edits outside the app and symlink changes.
   Seal the staged tree and refuse integration if tests, builds or review changed
   the index, left unstaged source edits, or added untracked source files. The
   committed patch must be the exact content that was validated.
6. For critical incidents, the independent reviewer must approve; reject and
   Unverified both prevent merge/install. Tests and an AI review do not prove the
   original real-world failure has stopped.
7. Commit the tested patch. Under the existing edit lock, require the original
   HEAD and app folder to be unchanged, then fast-forward. Otherwise retain the
   tested branch. The existing make-app installer preserves previous.app and the
   launcher rollback path. Check the installed commit stamp and write update-ready.
   Do not restart the running app, change launcher or replace known-good.
8. Report `installed_unverified` until a person checks the original failure.
   Notification requests are local macOS notifications containing only incident
   ID/state; whether macOS displays them depends on local notification settings.

The worker never labels an incident "fixed" solely from a build. Normal terminal
states include `no_code_change`, `needs_attention`, `review_rejected`, `failed`,
`interrupted`, `tested_branch`, `applied_unverified` and `installed_unverified`.
A matching repeated event updates its existing count, without starting an infinite
repair loop. A pipe handshake prevents new model/build code from starting before
its process group is durably registered; parent death closes the gate. Restart recovery verifies the tracked worker's PID/start time, waits
for termination of the entire process group (including surviving descendants),
and escalates to SIGKILL if necessary before scheduling another. A group whose
identity cannot be verified blocks new workers for inspection; it is not killed
blindly. Completed commands also have leftover child groups stopped. A monitoring or DB
failure after startup triggers cleanup and leaves uncertain registration intact;
the scheduler must recover it before it can start another job.
A restart puts an in-flight repair back on the queue when an attempt remains. A check that refused the patch stays stopped. A crashed model call tries again by itself, up to the attempt cap. The Retry button remains for a job that already hit that cap. Agent labels
are the agent's name / repair-daemon plus incident/run IDs; OS account remains the owner's.

## Limits and configuration

Default: 15-second settle time, three repair attempts per fingerprint, six model
calls per rolling hour (diagnosis, repair and review each count), 900 seconds per
model call, one worker, at most eight retained worktrees and 2,000 incidents.
When there is insufficient hourly capacity for the whole planned workflow, work
waits without starting a model. Queue overflow is exposed by `queue_overflow`;
new incidents beyond the cap are not retained. Increase limits only deliberately.

Successful/no-change worktrees are removed; failed/tested source changes remain
for inspection, with generated build products discarded to limit disk use. Git
branches retain tested commits. Inspect/remove obsolete **doctor-owned** worktrees
with git worktree commands before raising capacity limits; do not remove arbitrary
user worktrees. Model calls use each CLI's default model unless the route's
`model`/`review_model` is set. This wrapper enforces time/call limits, not a dollar
spending cap. A new repair will not overwrite a build awaiting restart.

Configuration: `~/.ragnarok/doctor/config.json`. It is JSON data, never sourced as
shell. Route changes take effect after restarting the daemon. `auto_install:false`
still allows tested code to merge; it leaves the built app uninstalled. Fallback only follows the route's
`agents` list, and each switch is written to the incident's history.

```sh
bin/ragnarok-doctor init       # once; refuses to overwrite an existing config
bin/ragnarok-doctor install    # register/restart the per-user LaunchAgent
bin/ragnarok-doctor status
bin/ragnarok-doctor show INCIDENT_ID
bin/ragnarok-doctor retry INCIDENT_ID
bin/ragnarok-doctor uninstall  # stop/unregister; preserve queue/config/artifacts
bin/ragnarok-doctor selfcheck
```

Manual retry still obeys `max_attempts`; increase it explicitly (maximum 3) if an
incident has exhausted its attempts. First inspect its source changes and check
artifacts. Running `once` while the service owns its singleton lock is refused.
`install` uses the current logged-in user's GUI launchd domain, never sudo.

## Validation

`checks/doctor-check.py` uses disposable git repositories and fake model responses.
It exercises before/after tests, real scratch commits/merges, critical review
approval/rejection/Unverified, escalation, changed original HEAD, protected/outside
edits, dirty trees, duplicates, missing/rotated/partial logs, persistence, bounds,
timeouts, restart recovery and private file modes. Installer tests use a fixture
and check its commit stamp; they do not replace the real app.

A separate real Codex connectivity smoke check returned structured Unverified
output without inspecting app files. These checks do not demonstrate a real
production repair or successful recovery from an actual app incident. App-level
logging gaps identified by the earlier audit still limit what this watcher sees.

Pre-deployment review found and was followed by regressions for source mutation
during validation, rotated files larger than one read batch, and a worker that
ignores SIGTERM. These checks are included in the test suite.

The suite contains 45 checks, including the agent order and fallback. Additional smoke checks used a real headless
Codex structured response and a live watcher process with a temporary source, the
real scrubber, singleton enforcement and cursor restart; that watcher test made
zero model calls. A final independent read-only review approved the post-release
worker-cleanup/recovery path after the identified defects were corrected.
