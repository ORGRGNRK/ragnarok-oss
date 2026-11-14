# Logging and attribution

App errors use schema version 2 and retain `ts`, `level`, `area`, `message`,
and optional NSError `domain`/`code`. Added fields:

| Field | Source |
| --- | --- |
| os_user | Actual OS account; independent of actor |
| actor | RAGNAROK_ACTOR |
| run_id | RAGNAROK_RUN_ID, then legacy RAGNAROK_AGENT_RUN |
| origin | RAGNAROK_ORIGIN, default app |
| incident_id | RAGNAROK_INCIDENT_ID |
| process_session | UUID generated once per app process; not an agent run ID |
| build | Bundle's commit resource |

Missing actor, run, incident and build values render as `Unverified`. Old app-error
rows have no actor evidence and also render as `Unverified`. A normal app process
is not attributed to whichever AI last edited it. Labels are supplied by launchers;
they are not authenticated identity or OS account isolation. Agent runner, app-edit
and project-heal child processes receive explicit actor, origin and run labels.
Incident IDs are propagated when supplied; this change does not create incidents.

## Run the two-pass audit

From the app directory:

```sh
bin/ragnarok-logging-audit
# Optional Claude runner (requires available Claude account usage):
bin/ragnarok-logging-audit --runner claude --budget 3
# Prepare source evidence, coverage and schema without invoking a model:
bin/ragnarok-logging-audit --prepare-only
python3 checks/logging-audit-check.py
```

The domain is debugging and observability: process, network, persistence, parsing
and UI failure boundaries. Discovery collects up to 24 plausible candidates and
forces their decisions to `Unverified`. A separate strict prompt receives the
same evidence plus candidates and returns `Log`, `Skip`, or `Unverified` for each.
`Log` means supported by static review, not reproduced or runtime verified.
No finding automatically changes source or launches a repair.

Each finding has an ID, exact file/line, domain, observed behavior, possible
impact, decision, reason, safe fields and proposed verification. The host rejects
invented source locations, duplicate/new IDs and moved candidate locations;
omitted candidates remain `Unverified`. The model's semantic judgment can still
be wrong and needs engineering review before instrumentation changes.

Evidence consists of numbered excerpts around `catch`, `try?`, process/HTTP status
checks and existing logging in top-level `Sources/Heimdall/*.swift`, excluding
SelfTest.swift. The manifest records exact ranges and file hashes. Other modules,
scripts, unselected lines, live logs and runtime behavior are excluded. Excerpts
are sent to the selected AI provider; no live logs, user files or credentials are
read by this audit. Expected missing data, optional fallback and cancellation do
not automatically need error logging.

Private artifacts are saved under `~/.ragnarok/logging-audits/<run>/` (directory
0700, files 0600): coverage, schema, both prompts, both JSON responses and a report.
Codex runs from an isolated temporary directory with user config/rules ignored,
read-only sandbox and shell/apps disabled. Claude uses safe/restricted mode, no
MCP servers and an empty tools list. Each pass has a 600-second timeout. Claude's
budget is per pass; Codex has no dollar cap in this wrapper. A failed process or
invalid result is not accepted as a successful audit. This is an on-demand audit,
not an always-on watcher or automatic repair daemon.
