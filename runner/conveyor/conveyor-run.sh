#!/usr/bin/env bash
# Conveyor runner — one leg per invocation, verify/ before queue/.
#
# DRIVER leg (PLAN.md Slice 2): oldest task in queue/ goes to a headless
# seat (claude -p, or codex exec since 2026-09-03) with executor-preamble.md
# prepended. After a RESULT: done claim
# the runner TRUSTS THE CHECKER, NOT THE EXECUTOR: it re-runs conveyor-check
# itself. All ticked (HUMAN excepted) → verify/. Any non-HUMAN step unticked
# → the checker's verdicts are appended under "## Leg N — driver" and the
# task returns to queue/. Only unticked HUMAN steps left → human/ plus ONE
# proposed intent.
#
# SPEC leg (2026-09-04): a task with NO "## Checklist" section does not get a
# driver leg — it gets a SPEC seat (spec-preamble.md, shorter timeout) whose
# only permitted write is appending "## Spec" + "## Checklist" to the task
# file, ending "RESULT: spec". The runner validates the shape (both sections,
# ≥1 command step, EXACTLY one HUMAN step — conveyor-tap ticks every HUMAN box
# on approve, so a second one would be ruled on unseen), then parks the task
# in human/ and mints ONE proposed intent whose ref is `conveyor:<task>:spec`
# and whose body is the spec itself. the operator's tap sends it to queue/ for its
# first real driver leg; his dismiss files it. Before this, a no-checklist
# task went straight to done/ on the seat's own claim — the 08-31 failure
# the operator named ("their 'done' was the model's own claim"). A spec leg that ends
# any other way (RESULT: done — it built instead; blocked; malformed spec)
# bounces to queue/ with a "## Leg N — spec" note, ceiling-only, never done/.
# The way to skip the spec leg is to write the checklist yourself: the
# checklist IS the spec.
#
# VERIFY leg (Slice 3): oldest task in verify/ goes to a FRESH seat with
# verifier-preamble.md — adversarial, assume the driver is wrong. The runner
# pre-checks at staging (a regression bounces the task back to queue/
# without spending a leg; the output rides into the prompt as evidence).
# VERDICT: pass → done/, but only after a post-check — the slice-2 principle
# applies to the second seat too, so a pass over an unticked non-HUMAN step
# is OVERRIDDEN back to queue/ (deliberate addition beyond the plan's
# letter). VERDICT: fail → the verifier's CONFIRMED/REFUTED lines and final
# verdict are appended under "## Leg N — verifier" and the task returns to
# queue/. The checklist is append-only in every seat.
#
# STOP RULE (Slice 4): FORWARD PROGRESS = SILENCE. There is no leg cap while
# a task is moving, however many legs it takes. A DEAD END is one of three
# things, and it is the only thing that flags the operator:
#   1. a full round trip (driver + verify) that ticked no new box and
#      discovered no new step;
#   2. the same step REFUTED twice by the verifier seat;
#   3. the backstop ceiling of 10 legs.
# On a dead end the task goes to failed/ with its whole leg/verdict history
# intact — the task file IS the loss record — plus one proposed intent, one
# notify carrying the last verdict, and one the author's database receipt. the operator,
# 2026-08-31: "sub and if forward progress no flag if dead end yes loop it
# back in and receipt We learn less from our wins and more from our loss."
#
# WHICH BOUNCES ARE ROUND TRIPS, and why it matters. Rule 1 is evaluated ONLY
# at the two verify-side returns (VERDICT: fail, and a pass overridden by the
# post-check) — the plan's own words are "a round trip (driver + verify)". A
# driver leg that bounces on its own check has not completed a round trip: it
# is the FIRST half of one, and a task whose second leg re-fails the same
# still-unwritten step is the normal shape of work, not a dead end. Same for
# the staging pre-check bounce, which by design spends no leg at all. Those
# two are governed by the ceiling alone. Reading this any wider makes an
# ordinary two-try fix flag the operator, which is the exact opposite of the ruling.
#
# Progress is measured against a BASELINE captured at driver-leg start
# (logs/<slug>.baseline, via `conveyor-check --list` — no commands run). If
# the baseline is missing the round counts as progress: never flag a task on
# the strength of not knowing. The ceiling still backstops that case.
#
# Exit codes are PIPELINE HEALTH ONLY (intent-executor lesson): a task that
# fails moves to failed/ (or bounces to queue/) and the runner still exits
# 0. Non-zero means the BELT broke — an mv, a receipt/task-file append, the
# human/ intent mint, or any of a dead end's surfacing steps failed (08-30
# audit: never exit 0 over those). A dead end nobody hears about is the
# failure this slice exists to prevent, so it breaks the belt loudly. LOUDLY
# IS NOW A MECHANISM, not a hope: conveyor.service carries
# OnFailure=backup-alert@%n.service, the same handler the backup and
# crew-doctor units use, so a non-zero exit reaches the operator's phone with the
# journal tail attached instead of stopping at journald (added 2026-09-01
# after the 19:11:04 crash above went unheard).
#
# EVERY ANSWER IS HEARD (2026-09-04). Until today a driver leg that ended
# "RESULT: blocked" — the cleanest "this cannot be done, here is why" a seat
# can give — got a move to failed/ and one receipts.jsonl line: no card, no
# notify, no the author's database row, and `the author's status tool` does not show failed/. Same for a
# seat that ended with no RESULT line at all (crash or cut-off), and for a
# verifier with no VERDICT line. the operator, on what the legs are for: "its
# supposed to check if its really something that can be done" — so the answer
# the legs exist to give was the one nobody heard. All three now route through
# dead_end() with a reason naming which it was and quoting the seat's final
# line; the receipts.jsonl verdict stays blocked / no-result-line /
# verify-no-verdict so history still tells them apart from a stop-rule dead
# end. The belt's own timeout (rc 124/137) is the cut-off case with the leg
# CHARGED — bump_legs's rule: a task that hangs every seat must still reach
# the ceiling.
#
# A SEAT CRASH IS NOT A TASK OUTCOME (same day, from a live loss at 20:57:
# codex hit usage_limit_exceeded 52 s into a spec leg and the task was filed
# as failed, silently, with a leg charged for a seat that never ran). Any
# other nonzero seat rc is the BELT having no working seat: the task goes back
# where it came from, byte-for-byte as it was before the leg (a half-written
# ## Spec must not become next tick's checklist), the leg is refunded, one
# "## Leg N — seat crash" note quotes the error line, and the operator is told ONCE
# per incident (logs/seat-crash.notified, cleared by the next seat that
# returns 0) AND the belt backs off before spending another leg
# (logs/seat-crash.backoff -- see BACKOFF below). Until 2026-09-04 this
# paragraph said the incident "will not repeat until a seat succeeds", which
# was true of the notify and false of the retry, in the same sentence -- the
# dedup lived in this prose and only half of it lived in the path. That half
# cost two plans in one evening. The runner exits nonzero on the tick that OPENS the incident and
# 0 on suppressed repeats — deliberately: conveyor.service's OnFailure=
# handler (backup-alert.sh) has no dedup of its own, so nonzero on every
# 5-minute tick would page the phone twelve times an hour, the exact spam the
# notify dedup exists to prevent, on a second channel. Every repeat is still in
# the task file and receipts.jsonl (verdict seat-crash).
#
# PROVENANCE (slice 5, 2026-09-01): every seat this script launches runs with
# CREW_ACTOR=conveyor exported, so hooks/log-tool.sh stamps its tool calls
# "agent:conveyor" in merged.jsonl. Before this, a conveyor leg was
# indistinguishable from any other headless claude run — producer=claude,
# actor=agent — and the watcher's "conveyor-actor wrote outside the allowed
# roots" check had nothing to key on. The hook prefixes "agent:" itself and
# never claims a person, so this names the SEAT, not a human pane.
#
# CONVEYOR_ROOT / CONVEYOR_CLAUDE / CONVEYOR_CODEX / CONVEYOR_GROK / CONVEYOR_INTENTS_URL /
# CONVEYOR_DRIVER_SEAT / CONVEYOR_VERIFIER_SEAT / CONVEYOR_NOTIFY /
# CONVEYOR_YGG are overridable so
# the routing can be proven with stubs (examples/slice2-demo.sh,
# slice3-demo.sh, slice4-demo.sh) — the prose-drift stubbable-sender pattern.
# The notify and the author's database senders are overridable for the same reason
# icloud-push.sh makes NOTIFY overridable: the author's notify sender reaches the operator's
# phone, so a test that cannot stub it cannot be run. Defaults are the live
# belt.
set -u

# --- self-snapshot guard begin ---
# WHY THIS EXISTS. Bash reads a script incrementally, by byte offset, while it
# runs. Edit the file in place and the offsets shift under the live process,
# which then resumes mid-token. That is not theoretical: 2026-09-01 19:11:04
# conveyor.service exited 2 with `syntax error near unexpected token 'then'`
# at line 563 (`if ! fuser "$ROOT/.lock" ...`) because the leg it was running
# had just committed an edit to THIS file. The belt died inside its own
# crash-recovery loop. A conveyor task that improves the conveyor is a normal
# task -- this slice is one -- so the belt has to survive being edited while
# it runs.
#
# FIX: re-exec once from an immutable snapshot. The copy is a fresh inode in
# TMPDIR whose name nothing else on the box knows, so no edit, commit, rebase
# or checkout can reach the bytes bash is reading. The live file is free to
# change; this run finishes on the code it started with.
#
# KEYED ON THE RESOLVED PATH, NOT ON "is the variable set". Every seat this
# runner launches inherits its environment, so a set-ness test would make a
# nested run (a demo, a conveyor leg building the conveyor) skip the snapshot
# and read the editable file -- reintroducing the exact defect one level down.
if [ "${CONVEYOR_SELF_SNAPSHOT:-}" != "$(readlink -f "$0")" ]; then
  __conveyor_self="$(readlink -f "$0")"
  __conveyor_snap="$(mktemp "${TMPDIR:-/tmp}/conveyor-run.XXXXXXXX.bash")" || exit 70
  # Resolve it, or the guard above never matches where TMPDIR runs through a
  # symlink (macOS: /var -> /private/var) and the runner re-execs forever.
  __conveyor_snap="$(readlink -f "$__conveyor_snap")" || exit 70
  cat "$__conveyor_self" > "$__conveyor_snap" || { rm -f -- "$__conveyor_snap"; exit 70; }
  # SELF_DIR below resolves CODE siblings (conveyor-check, the preambles, the
  # the author's database receipt writer) from $0. Under the snapshot $0 is in TMPDIR, so
  # the original path has to be carried across the exec or every sibling
  # lookup breaks.
  export CONVEYOR_SELF="$__conveyor_self"
  export CONVEYOR_SELF_SNAPSHOT="$__conveyor_snap"
  exec bash "$__conveyor_snap" "$@"
fi
# BASHPID, not $$: $$ is the same in a subshell, so an unguarded EXIT trap
# firing in one would delete the snapshot out from under the still-running
# parent -- the same class of failure this guard exists to close.
__conveyor_main_pid="$BASHPID"
trap '[ "$BASHPID" = "$__conveyor_main_pid" ] && rm -f -- "${CONVEYOR_SELF_SNAPSHOT:-}"' EXIT
# --- self-snapshot guard end ---
ROOT="${CONVEYOR_ROOT:-$(dirname "${CONVEYOR_SELF:-$(readlink -f "$0")}")}"
QUEUE="$ROOT/queue"; RUNNING="$ROOT/running"; DONE="$ROOT/done"
FAILED="$ROOT/failed"; VERIFY="$ROOT/verify"; HUMAN="$ROOT/human"
PLAN="$ROOT/plan"   # planning first (2026-10-26, SPEC-planning.md): opt-in tray before queue/
LOGS="$ROOT/logs"
CLAUDE="${CONVEYOR_CLAUDE:-$HOME/.local/bin/claude}"

# ---- A SECOND BELT ON THE SAME CODE (2026-09-11) -----------------------------
# the operator, 2026-09-11 16:15 and 16:20 verbatim: "i need two one is for incoming
# and one is for outgoing", "incoming from someone elses question would go
# through a different conveyer and put into a different folder". Tapped
# approved as intent #132.
#
# EVERYTHING A SECOND BELT NEEDS WAS ALREADY HERE EXCEPT TWO THINGS, and the
# first leg's job was to find out which. The lock is "$ROOT/.lock", so it is
# PER-ROOT, not global: two belts with different CONVEYOR_ROOT take different
# locks and run side by side rather than in turns. Same for .tap.lock,
# .intent-reader.lock, the per-task stop-rule state (state_file -> $LOGS) and
# the seat backoff/crash files ($LOGS/seat-crash.*), all of which are under
# ROOT. Proven both directions by tests/two-roots.sh, whose negative control is
# two runners on the SAME root.
#
# The two things that were NOT per-root are below.
#
# 1. REF_PREFIX. Every intent this runner mints was hardcoded `conveyor:<task>`.
#    Two belts minting under one prefix would put a stranger's spec card in
#    the operator's queue looking exactly like his own work, and conveyor-tap (which
#    selects on that prefix) would service whichever root it happened to be
#    pointed at. His words: "its own item_ref prefix so its cards are visibly
#    not the operator's own work". conveyor-tap reads the same variable, and the
#    partition is written on the OTHER doors too — conveyor-intent-reader's
#    classification table and intent-executor's NOT_THIS_DOOR — because a
#    filter on one side only is a race, not a partition.
REF_PREFIX="${CONVEYOR_REF_PREFIX:-conveyor:}"
# 2. SPEC_ALWAYS. His words: "a spec leg ALWAYS first since a stranger's
#    wording cannot be clarified mid-build". Off (the default), leg type is
#    decided by whether the task carries a "## Checklist" — which is the right
#    rule for the operator, who can be asked. It is the wrong rule for a request from
#    someone else: their text is not editable by the belt, they cannot be
#    asked mid-build, and a body that merely CONTAINS a checklist-shaped
#    section would skip straight to a driver leg whose `:: verify:` commands
#    conveyor-check then EXECUTES as the operator. On, the spec seat runs until the
#    file carries a "## Spec" heading, and only this runner's route_spec ever
#    writes that heading — so a submitted checklist cannot buy its way past
#    the spec seat. conveyor-request quarantines the body as well; this is the
#    belt-side backstop for a task that arrived by any other path.
SPEC_ALWAYS="${CONVEYOR_SPEC_ALWAYS:-0}"
# ------------------------------------------------------------------------------
# The checker and preambles are CODE, resolved beside this script — only the
# belt state (queue/running/...) lives under ROOT, which tests may redirect.
SELF_DIR="$(dirname "${CONVEYOR_SELF:-$(readlink -f "$0")}")"

# ---- STANDALONE MODE (2026-09-08) --------------------------------------------
# Opt-in via CONVEYOR_STANDALONE=1, for a machine that is not the author's server: no
# the author's notify sender, no the author's database, no dashboard on :4200. It sets the CONVEYOR_*
# variables the defaults further down ALREADY read, so no other assignment in
# this file changes, and with CONVEYOR_STANDALONE unset every path below is
# byte-identical to the behaviour before this block existed.
#
# WHY THE THREE PREFLIGHT `die`s EXIST AND ARE KEPT: a belt that cannot surface
# a loss must say so on every run, not months later when the first dead end
# happens to discover it. Standalone does not remove that guarantee — it
# redirects it. The loss still gets written; it lands in logs/ instead of
# the operator's phone and his base.
#
# NOT A SILENT FALLBACK, deliberately. If these swapped in automatically
# whenever the author's notify sender went missing, a broken sender on the author's server would
# quietly downgrade the operator's phone alerts to a log file nobody reads — the exact
# write-only failure this package keeps finding everywhere else. Standalone is
# a DECLARED mode or it is off.
if [ "${CONVEYOR_STANDALONE:-0}" = "1" ]; then
  : "${CONVEYOR_NOTIFY:=$SELF_DIR/standalone/notify-local}"
  : "${CONVEYOR_YGG:=$SELF_DIR/standalone/receipt-local}"
  : "${CONVEYOR_CLOSE:=$SELF_DIR/standalone/close-local}"
  export CONVEYOR_NOTIFY CONVEYOR_YGG CONVEYOR_CLOSE
fi

# WHAT A DEAD END TELLS ITS READER is the one place a release cannot afford to
# be wired to the author. Everything above redirects a CHANNEL; these three
# strings are the WORDS that come out of it. On the author's server the loss lands as a card
# in the dashboard queue and conveyor-tap services its two verbs, so the text
# names them. A stranger has no card, no queue and no tap, and text telling
# them to tap one is worse than silence: the loss record - the very artifact
# this belt exists to preserve - would end in an instruction that cannot be
# followed. Standalone names the files it actually wrote and the two moves a
# person makes by hand.
#
# Found 2026-09-09 by reading the runner's OUTPUT rather than its plumbing,
# the same way the preambles were caught the day before. A scan in
# make-portable.sh now fails the build on an author name in an executed line,
# so the next one surfaces at build time instead of in a stranger's failed/.
# THE DEFAULTS HERE ARE THE PORTABLE ONES, and that is the structural point.
# The author's own wording - his dashboard, his card, his two tap verbs - lives
# in belt-text.sh, which the release does not ship, beside the other
# files that only make sense on his box. Written the other way round, with his
# text as the default and the generic text as the override, every string would
# still be sitting in the shipped runner where the next build could not tell
# them from the code. A name that must not ship should not be in the file that
# ships.
BELT_HOST="$(hostname 2>/dev/null || echo local)"
HUMAN_REF="a human"
RETRY_FMT='The loss is recorded where you can find it: this file, kept whole in failed/,\na line in logs/dead-ends.jsonl, and the notice in logs/notify.log. To put\n%s back on the belt, move this file from failed/ to queue/ and set\n"## Legs:" back to 0 - every leg above is kept on purpose, so the next\nattempt starts from these lessons and not from zero. The count above is the\nhistory. Leaving it in failed/ files it there.'
RETRY_LINE='Move it back to queue/ and reset "## Legs:" to 0 to put it on the belt again - legs restart at 0, every leg is kept - or leave it in failed/.'
BELT_TEXT="${CONVEYOR_BELT_TEXT:-$SELF_DIR/belt-text.sh}"
if [ "${CONVEYOR_STANDALONE:-0}" != "1" ]; then
  # PRESENT: use the author's wording. ABSENT: say so and keep the generic
  # wording — do NOT die.
  #
  # It died here for about twenty minutes on 2026-09-09 and that was wrong, on
  # this package's own rule that an exit code is PIPELINE health and never a
  # task outcome. Missing text degrades the WORDING of a dead-end alert; the
  # dead end itself is still written to the task file, still notified, still
  # receipted, still minted as an intent. Refusing to start would convert a
  # cosmetic loss into a total belt outage — a strictly worse failure than the
  # one it was guarding. It also broke every test that builds a mutated copy of
  # this runner in a temp directory as its negative control, which is how the
  # mistake was caught: blocked-surfaced.sh and hand-tick-erased.sh went from
  # 0 failures to 36 between them.
  #
  # The release cannot reach this branch anyway: without CONVEYOR_STANDALONE=1
  # the notify/receipt/close preflight already refuses, and that guard is the
  # one that protects the thing worth protecting.
  if [ -r "$BELT_TEXT" ]; then
    . "$BELT_TEXT"
  else
    echo "conveyor: no belt text at $BELT_TEXT — using the portable wording" >&2
  fi
fi
# ------------------------------------------------------------------------------

CHECK="$SELF_DIR/conveyor-check"
# PREAMBLES ARE BOX-SPECIFIC AND THE SHIPPED ONES SAY SO. They open "You are
# the CONVEYOR EXECUTOR on <host>", instruct the seat to work within "the operator's
# standing write authority" and to "write a receipt to the author's database", and cite
# /opt, n8n and pm2 by name — correct, because they are instructions for a seat
# working HERE. Standalone swaps in generic variants that keep every rule and
# drop the box.
#
# This was missed when standalone mode shipped earlier the same day: the
# runner was portable and the INSTRUCTIONS IT HANDS THE MODEL were not, so a
# stranger's first leg would have been told it was on a machine it had never
# heard of, working for someone it had never met, and to write to a base it
# cannot reach. Found by reading the preambles, not by any test — which is why
# tests/standalone.sh now greps them.
PRE_DIR="$SELF_DIR"
[ "${CONVEYOR_STANDALONE:-0}" = "1" ] && PRE_DIR="$SELF_DIR/standalone"
PREAMBLE="$PRE_DIR/executor-preamble.md"
VPREAMBLE="$PRE_DIR/verifier-preamble.md"
SPREAMBLE="$PRE_DIR/spec-preamble.md"
PPREAMBLE="$PRE_DIR/planner-preamble.md"
CPREAMBLE="$PRE_DIR/critic-preamble.md"
INTENTS_URL="${CONVEYOR_INTENTS_URL:-http://127.0.0.1:4200/api/intents}"
TASK_TIMEOUT="${CONVEYOR_TASK_TIMEOUT:-3600}"
# A spec should take minutes, not an hour. A spec seat still running at 15
# minutes is almost certainly building — the one thing its preamble forbids —
# and the timeout is the structural guard the preamble cannot be.
SPEC_TIMEOUT="${CONVEYOR_SPEC_TIMEOUT:-900}"
# Timeout coupling (slice 2/3): conveyor.service TimeoutStartSec=5400 must
# cover ONE invocation's worst case. Driver: 3600 + 120s×steps of post-leg
# checking. Verify: 120s×steps (pre) + 1800 + 120s×steps (post). Bump the
# unit if any of these grow.
VERIFY_TIMEOUT="${CONVEYOR_VERIFY_TIMEOUT:-1800}"
# Seat for verify legs. "claude" (default; same model, fresh context +
# opposed preamble is the independence — PLAN.md Slice 3) or "gemini"
# (free third seat; verified for read-and-answer only, so the preamble's
# degrade line applies — it judges from the staged check + file reads).
VERIFIER_SEAT="${CONVEYOR_VERIFIER_SEAT:-claude}"
# Seat for DRIVER legs. Same three values. Added 2026-09-03: the operator's Claude
# subscription ends ~09-14 (Reminders reczfVlT6jK1p9FBA) and the belt was the
# only thing on this box that dies with it — every other Claude dependency is
# a bill, not a build. The driver was hardcoded to claude while the verifier
# already had a seat branch, so half the plumbing existed and half did not.
DRIVER_SEAT="${CONVEYOR_DRIVER_SEAT:-claude}"
# PLANNING FIRST (2026-10-26, SPEC-planning.md). Only tasks added with
# `conveyor add --plan` (the plan/ tray) use these. The planner writes a
# checklist, the critic -- by default a DIFFERENT maker's seat, so the review
# is not the planner marking its own homework -- lists problems or approves.
# Their binaries are checked when a plan leg runs, not at startup, so a belt
# that never plans never needs them installed.
PLANNER_SEAT="${CONVEYOR_PLANNER_SEAT:-claude}"
if [ -n "${CONVEYOR_CRITIC_SEAT:-}" ]; then CRITIC_SEAT="$CONVEYOR_CRITIC_SEAT"
elif [ "$PLANNER_SEAT" = grok ]; then CRITIC_SEAT=claude
else CRITIC_SEAT=grok; fi
# A step of a PLANNED task that fails its check STEP_TRIES times goes, once, to
# this seat; unset (the default) means straight to the operator.
ESCALATE_SEAT="${CONVEYOR_ESCALATE_SEAT:-}"
PLAN_ROUNDS="${CONVEYOR_PLAN_ROUNDS:-2}"
STEP_TRIES="${CONVEYOR_STEP_TRIES:-3}"
PLAN_TIMEOUT="${CONVEYOR_PLAN_TIMEOUT:-$SPEC_TIMEOUT}"
# JSON TASKS (branch json-tasks, 2026-10-28). A planned task whose header says
# "plan-format: json" (conveyor-add --plan writes it unless told
# --plan-format markdown) is planned as ONE JSON object that matches
# task-schema/task.schema.json. Code validates it (conveyor-taskjson); an
# invalid answer goes back to the planner with the errors, up to
# CONVEYOR_PLAN_JSON_RETRIES more times in the same round. The critic answers
# with a JSON verdict (pass, or a list of issues). A PASS GOES STRAIGHT TO
# queue/ -- no human approval step; the guardrails are the validator's (scope,
# size, no "..", no secrets, a real test command) plus a scope/size check line
# the belt adds to the checklist. Tasks without that header plan exactly as
# before (markdown checklist, RESULT: plan / VERDICT: lines).
TASKJSON="${CONVEYOR_TASKJSON:-$SELF_DIR/conveyor-taskjson}"
JPPREAMBLE="$PRE_DIR/planner-json-preamble.md"
JCPREAMBLE="$PRE_DIR/critic-json-preamble.md"
JSON_RETRIES="${CONVEYOR_PLAN_JSON_RETRIES:-2}"
# claude and grok take --json-schema (both CLIs list it in --help); 0 turns it
# off and leaves prompt + extract. A seat that exits nonzero with it is tried
# once more without it in the same attempt.
JSON_NATIVE="${CONVEYOR_JSON_NATIVE_SCHEMA:-1}"
# THE REVIEW GATE (Ragnarok, 2026-10-30). The owner: "AI outputs are proposals;
# never auto-approve." With CONVEYOR_REVIEW_GATE=1 (runner/ragnarok/belt
# always sets it) nothing an AI says moves work forward on its own:
#   - a plan the critic passes (JSON or markdown) goes to human/ with an
#     unticked "you approve this plan" HUMAN box, not to queue/;
#   - work the checks AND the verifier pass goes to human/ as a proposed
#     result, not to done/. Only a person moves it to done/
#     (runner/ragnarok/belt accept), and only a person ticks a HUMAN box
#     (erase_hand_ticks already undoes a seat's tick).
# Off (the default) keeps the upstream behaviour byte-for-byte, so the
# upstream tests still prove the upstream belt.
REVIEW_GATE="${CONVEYOR_REVIEW_GATE:-0}"

# See PROVENANCE in the header. Exported once, inherited by both seats and by
# every tool-hook process they fire.
export CREW_ACTOR=conveyor
GEMINI="${CONVEYOR_GEMINI:-$HOME/.local/bin/gemini}"
CODEX="${CONVEYOR_CODEX:-$HOME/.local/bin/codex}"
# Grok Build (xAI). Its own installer (curl -fsSL https://x.ai/cli/install.sh | bash)
# puts the binary in ~/.grok/bin, not ~/.local/bin.
GROK="${CONVEYOR_GROK:-$HOME/.grok/bin/grok}"
# The local seat (run_seat). Ollama on this box; the model must make real tool calls.
LOCAL_URL="${CONVEYOR_LOCAL_URL:-http://127.0.0.1:11434}"
LOCAL_MODEL="${CONVEYOR_LOCAL_MODEL:-conveyor-general}"
# HOW the local seat talks to its model (2026-10-26, SPEC-planning.md). The
# model now lives on a bigger machine on the network, and every local server
# worth using (LM Studio, Ollama's /v1, llama.cpp, vLLM) speaks the OpenAI
# chat-completions API. "openai" (the default) runs conveyor-local-agent
# against CONVEYOR_LOCAL_BASE_URL; "anthropic" is the 2026-10-21 path, the
# claude CLI pointed at Ollama's Anthropic API at CONVEYOR_LOCAL_URL.
# CONVEYOR_LOCAL_API_KEY (optional) is read by the agent from the environment
# and never written to a log or a command line.
LOCAL_API="${CONVEYOR_LOCAL_API:-openai}"
LOCAL_BASE_URL="${CONVEYOR_LOCAL_BASE_URL:-http://127.0.0.1:1234/v1}"
LOCAL_AGENT="${CONVEYOR_LOCAL_AGENT:-$SELF_DIR/conveyor-local-agent}"
# Slice 4 surfacing path. NOTIFY reaches the operator's phone; YGG writes two rows to
# the live base. Both are only ever invoked on a dead end.
NOTIFY="${CONVEYOR_NOTIFY:-$HOME/bin/conveyor-notify}"
# This producer is system lane. Declared here rather than at each call
# site: the author's notify sender reads a lane variable and routes to the matching
# bot, so one buzz says which part of his life needs him.
# The lane env var this producer declares is set in belt-text.sh
# alongside the rest of the author-side wiring; standalone's notify ignores it.
YGG="${CONVEYOR_YGG:-$SELF_DIR/conveyor-ygg-receipt}"
# The belt closes what it finishes (2026-09-04, the operator: the money-tab cards
# "don't update"). conveyor-close tells the dashboard queue and any linked
# reminder row the outcome the runner has just SEEN — done/ or a dead end.
CLOSE="${CONVEYOR_CLOSE:-$SELF_DIR/conveyor-close}"
# The backstop ceiling. A task this deep is telling you something even if it
# is technically still moving (PLAN.md Slice 4).
LEG_CEILING="${CONVEYOR_LEG_CEILING:-10}"

die() { echo "conveyor: $*" >&2; exit 1; }
move() { mv "$1" "$2" || die "mv $(basename "$1") -> $2 failed"; }
# leg = the SPEND counter (## Legs: N in the task file), i.e. how many seats
# this task has cost. seat = who ran: driver, verifier, or "runner" for a
# routing decision the runner made with no model invoked at all (a staging
# pre-check bounce, a checker error, a stranded task). Note the leg number
# here and the "## Leg N" heading in the task file count different things on
# purpose: headings number the BLOCKS written, this numbers the SEATS spent,
# and a pre-check bounce writes a block without spending a seat.
# model_reported (added 2026-10-30, Ragnarok): the model name(s) the model API itself put in its
# answers (the response's "model" field) during the seats this receipt covers, comma separated in
# order, or null: for "runner" rows (no model ran) and for seats whose output carries no such field.
# It is NOT the configured model and NOT what an agent says about itself. Appended after "seat", so
# every older reader of these lines still finds the same fields.
SEAT_MODELS_REPORTED=""
receipt() { # ts task verdict rc log-json ("\"path\"" or null) leg seat
  local mr=null
  if [ "${7:-runner}" != runner ] && [ -n "$SEAT_MODELS_REPORTED" ]; then
    mr="\"$(printf '%s' "$SEAT_MODELS_REPORTED" | tr -d '"\\\000-\037')\""
  fi
  SEAT_MODELS_REPORTED=""
  printf '{"ts":"%s","task":"%s","verdict":"%s","rc":%s,"log":%s,"leg":%s,"seat":"%s","model_reported":%s}\n' \
    "$1" "$2" "$3" "$4" "$5" "${6:-0}" "${7:-runner}" "$mr" >> "$LOGS/receipts.jsonl" \
    || die "receipt append failed for $2"
}

# CLOSE THE LOOP, after the move and after the receipt line — the same order
# conveyor-tap uses for its PATCH: the belt's own record is on disk first, then
# the queue is told. $close_pending is set to done|failed by the filing site.
# A close that fails does NOT break the belt (a done task with a stuck card lost
# nothing) but writes a `close-failed` receipt so conveyor-status can show it.
close_pending=""
close_out() {
  [ -n "$close_pending" ] || return 0
  local where
  if [ "$close_pending" = done ]; then where="$DONE/$task"; else where="$FAILED/$task"; fi
  printf -- '\n--- conveyor-close (%s) ---\n' "$close_pending" >> "$log" 2>/dev/null || true
  if ! CONVEYOR_LEG_SEAT="${CONVEYOR_LEG_SEAT:-}" "$CLOSE" "$task" "$close_pending" "$where" "$ts" >> "$log" 2>&1; then
    receipt "$(date -Is)" "$task" close-failed 0 "\"$log\"" "${legspent:-0}" runner
  fi
  close_pending=""
}

# One dispatch for every seat the belt can spend, so the driver and verify legs
# cannot drift apart. Sets SEAT_RC and SEAT_FINAL. Appends; the caller owns
# truncation and the leg header.
#
# THE CONTRACT EVERY SEAT MUST MEET: $log receives the model's TEXT OUTPUT and
# nothing else. THREE readers depend on that and each greps the WHOLE file --
# dead_end()'s `^(VERDICT|RESULT): ` scan, the verify leg's
# `^(CONFIRMED|REFUTED): ` harvest, and record_refuted()'s tally.
#
# Which is why the codex seat is not a one-line swap, and this comment is here
# so nobody "simplifies" it back. `codex exec` ECHOES THE PROMPT into stdout,
# and the prompt is preamble + task file -- a file that already carries every
# previous leg's REFUTED lines. Piping raw codex stdout into $log would let
# record_refuted() re-count old refutations, and the "same step REFUTED twice"
# rule (slice 4) would fire a DEAD END on a task refuted exactly once. Measured
# 2026-09-03 against codex-cli 0.151.0: stdout carries a header block, then
# `user` + the full prompt, then `codex` + the reply. So the codex branch takes
# --json and writes ONLY agent_message text, which is the same shape claude's
# --output-format text already produces. Raw JSONL is kept beside the log for
# forensics; nothing parses it.
# LIVE VIEW, 2026-10-26: the claude-CLI seats (claude, local) stream JSON to
# a .jsonl beside the log, so a watcher -- the Mac app -- can show each step
# while the leg runs. With --output-format text nothing reached the log until
# the leg ended. The log still gets what text mode wrote: the final result.
# A jq failure leaves no result text, so SEAT_FINAL matches no verdict and the
# leg routes to failed/ -- the same safe direction as the codex seat.
seat_text() { # raw log
  jq -r 'select(.type == "result") | .result // empty' "$1" >>"$2" 2>>"$2" || true
}

# After each seat: note the model name(s) its API responses reported (the local agent's and the API
# seat's result line carry "model_reported"; a claude-style stream carries message.model).
note_models_reported() { # raw-jsonl
  local m
  [ -s "$1" ] || return 0
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case ",$SEAT_MODELS_REPORTED," in *",$m,"*) ;; *) SEAT_MODELS_REPORTED="${SEAT_MODELS_REPORTED:+$SEAT_MODELS_REPORTED,}$m" ;; esac
  done < <(jq -r '(select(.type == "result") | .model_reported // empty), (select(.type == "assistant") | .message.model // empty) | strings' "$1" 2>/dev/null | tr ',' '\n')
}

run_seat() { # seat timeout prompt log
  run_seat_once "$@"
  local r=$?
  note_models_reported "${4%.log}.jsonl"
  return $r
}

run_seat_once() { # seat timeout prompt log
  local seat="$1" tmo="$2" sprompt="$3" slog="$4" raw
  raw="${slog%.log}.jsonl"
  # JSON tasks: SEAT_JSON_SCHEMA (set only by the JSON plan leg) asks the CLI
  # for schema-constrained output. Empty everywhere else, so no other leg changes.
  local jflag=()
  [ -n "${SEAT_JSON_SCHEMA:-}" ] && [ "$JSON_NATIVE" = 1 ] && jflag=(--json-schema "$SEAT_JSON_SCHEMA")
  case "$seat" in
    claude)
      # THE CONNECTOR FENCE, 2026-10-21. A seat runs on the operator's claude.ai login,
      # and that login carries his connectors: measured that day, an unfenced
      # seat loaded 131 MCP tools -- Gmail, Inkbox (email/SMS/iMessage), Google
      # Calendar, the author's database, Claude Docs and the author's database WRITES as "Claude Code".
      # Unattended and permission-skipping, that is a seat that can send as him.
      # Both switches below drop it to 24 built-in tools, 0 MCP (measured, not
      # assumed: the stream-json init line lists what loaded). Two because each
      # is one line someone could lose. NOT A WALL: a seat has bash and could
      # start its own claude without them. The wall is a seat login that has no
      # connectors at all (an API key) -- the operator's call, recorded in the README.
      ENABLE_CLAUDEAI_MCP_SERVERS=false timeout "$tmo" "$CLAUDE" -p "$sprompt" \
        --dangerously-skip-permissions \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --output-format stream-json --verbose ${jflag[@]+"${jflag[@]}"} >"$raw" 2>>"$slog"
      SEAT_RC=$?
      seat_text "$raw" "$slog" ;;
    api)
      # THE API SEAT (json-tasks). One chat-completions call to any
      # OpenAI-compatible server, with the schema as response_format
      # json_schema. No tools, so it plans and critiques from the prompt alone
      # (it cannot read the repo). For planner/critic only. Settings:
      # CONVEYOR_API_BASE_URL, CONVEYOR_API_MODEL, CONVEYOR_API_KEY_ENV (the NAME
      # of the variable holding the key; default CONVEYOR_API_KEY), and the same
      # with CONVEYOR_PLANNER_API_ / CONVEYOR_CRITIC_API_ to use two providers.
      printf '%s' "$sprompt" | CONVEYOR_API_ROLE="${SEAT_ROLE:-}" CONVEYOR_API_SCHEMA_FILE="${SEAT_JSON_SCHEMA_FILE:-}" \
        timeout "$tmo" python3 "$TASKJSON" api >"$raw" 2>>"$slog"
      SEAT_RC=$?
      seat_text "$raw" "$slog" ;;
    local)
      if [ "$LOCAL_API" = openai ]; then
        # The prompt goes on stdin, not argv: a task file has no business in
        # the process list. The agent's stdout is stream-json (seat_text).
        printf '%s' "$sprompt" | CONVEYOR_LOCAL_BASE_URL="$LOCAL_BASE_URL" CONVEYOR_LOCAL_MODEL="$LOCAL_MODEL" \
          timeout "$tmo" python3 "$LOCAL_AGENT" >"$raw" 2>>"$slog"
        SEAT_RC=$?
        seat_text "$raw" "$slog"
        SEAT_FINAL=$(awk 'NF {last=$0} END {print last}' "$slog")
        return 0
      fi
      # THE LOCAL SEAT, 2026-10-21, the operator: the `conveyor` user's belt runs "a
      # small model that's already on my computer". It is the claude CLI with
      # its API pointed at Ollama on the host's GPU (Ollama speaks the
      # Anthropic /v1/messages API, tool_use included), so the agent loop, the
      # tools and the text-only log contract are the claude seat's, unchanged.
      # Measured that day: conveyor-general (qwen2.5:7b, num_ctx 32768) makes
      # real tool calls; qwen2.5-coder:7b writes them out as TEXT and does
      # nothing, so it is not the default however apt the name sounds.
      # ANTHROPIC_API_KEY is emptied so a key in the environment cannot route
      # a "local" leg to a paid API, and the connector fence is kept: the
      # seat's claude.ai login still carries the operator's connectors.
      ANTHROPIC_BASE_URL="$LOCAL_URL" ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY= \
      ANTHROPIC_MODEL="$LOCAL_MODEL" ANTHROPIC_SMALL_FAST_MODEL="$LOCAL_MODEL" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ENABLE_CLAUDEAI_MCP_SERVERS=false \
        timeout "$tmo" "$CLAUDE" -p "$sprompt" \
        --dangerously-skip-permissions \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --output-format stream-json --verbose >"$raw" 2>>"$slog"
      SEAT_RC=$?
      seat_text "$raw" "$slog" ;;
    gemini)
      timeout "$tmo" "$GEMINI" -p "$sprompt" >>"$slog" 2>&1
      SEAT_RC=$? ;;
    codex)
      # </dev/null is load-bearing: with stdin piped, codex APPENDS it to the
      # prompt as a <stdin> block, so an inherited pipe silently mutates the
      # task the seat is given.
      timeout "$tmo" "$CODEX" exec "$sprompt" --json \
        --dangerously-bypass-approvals-and-sandbox \
        --skip-git-repo-check -C "$HOME" </dev/null >"$raw" 2>>"$slog"
      SEAT_RC=$?
      # A jq failure leaves $log holding only stderr, so SEAT_FINAL matches no
      # verdict and the leg routes to failed/. That is the correct direction:
      # an unreadable seat must never look like a silent pass.
      jq -r 'select(.item.type == "agent_message") | .item.text' "$raw" \
        >>"$slog" 2>>"$slog" || true ;;
    grok)
      # THE GROK SEAT, 2026-10-26 (Grok Bot, the operator: "can you make a
      # handler for grok cli"). Grok Build's headless mode is the claude seat's
      # shape: -p runs one prompt with tools and exits, --always-approve is
      # its permission skip, and --output-format streaming-messages-json is
      # documented as Claude's stream-json wire format (system/init, assistant,
      # user, and a final {"type":"result","result":...}). So seat_text and
      # the Mac app's live view read it unchanged. Flags from Grok Build
      # 1.0.70's own --help and docs/user-guide/14-headless-mode.md, not
      # guessed. Login: `grok login` (browser) or XAI_API_KEY, inherited.
      #
      # THE FENCE. Grok also loads Claude Code's and Cursor's hooks and MCP
      # servers by default (compat). Measured with `grok inspect` that day:
      # the operator's six ~/.claude/settings.json hooks load into a grok
      # session, and these four documented switches mark them [disabled].
      # Grok's OWN MCP servers and plugins (none on the Mac that day) still
      # load; there is no --strict-mcp-config equivalent. NOT A WALL, same as
      # the claude seat: the seat has bash.
      # --no-auto-update: the docs ask for it in scripts. </dev/null: headless
      # grok does not read stdin, so this only keeps an inherited pipe out.
      GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false \
      GROK_CURSOR_HOOKS_ENABLED=false GROK_CURSOR_MCPS_ENABLED=false \
        timeout "$tmo" "$GROK" --no-auto-update -p "$sprompt" \
        --always-approve \
        --output-format streaming-messages-json ${jflag[@]+"${jflag[@]}"} </dev/null >"$raw" 2>>"$slog"
      SEAT_RC=$?
      seat_text "$raw" "$slog" ;;
    *) die "unknown seat: $seat (want claude|gemini|codex|grok|local|api)" ;;
  esac
  # ONE parser for every seat -- the verdict is the final non-blank line,
  # matched exactly (08-30 audit: a leg that merely QUOTED a verdict mid-stream
  # used to file as done).
  SEAT_FINAL=$(awk 'NF {last=$0} END {print last}' "$slog")
}

# ---- Slice 4 bookkeeping -----------------------------------------------------
# All of it keyed off the task slug and kept in logs/, NOT in the task file:
# the task file is cat'd verbatim into the executor's prompt and that seat runs
# with --dangerously-skip-permissions, so the runner's own stop-rule state has
# no business being in there. The one exception is "## Legs: N", which the plan
# puts in the file on purpose — it is for the reader, and for the seat, to see.
# Is a seat runnable here? Prints the reason and returns 1 when not. Used at
# startup for the driver and verifier, and by a plan leg (planner, critic) and
# an escalation (the escalate seat) just before they spend one -- so a belt
# that never plans never needs those binaries.
local_models() { # GET $LOCAL_BASE_URL/models; the key goes in on stdin, never argv
  { [ -n "${CONVEYOR_LOCAL_API_KEY:-}" ] && printf 'header = "Authorization: Bearer %s"\n' "$CONVEYOR_LOCAL_API_KEY" || true; } \
    | curl -fsS -m 5 -K - "$LOCAL_BASE_URL/models" 2>/dev/null
}
seat_check() { # seat
  case "$1" in
    claude) [ -x "$CLAUDE" ] || { echo "claude seat selected but no binary at $CLAUDE"; return 1; } ;;
    gemini) [ -x "$GEMINI" ] || { echo "gemini seat selected but no binary at $GEMINI"; return 1; } ;;
    codex)  [ -x "$CODEX" ] || { echo "codex seat selected but no binary at $CODEX"; return 1; }
            command -v jq >/dev/null 2>&1 \
              || { echo "codex seat selected but jq is missing (needed to extract agent messages)"; return 1; } ;;
    local)
      if [ "$LOCAL_API" = openai ]; then
        local models
        [ -r "$LOCAL_AGENT" ] || { echo "local seat selected but conveyor-local-agent is missing at $LOCAL_AGENT"; return 1; }
        models=$(local_models) \
          || { echo "local seat selected but $LOCAL_BASE_URL/models did not answer (is the model server running and reachable?)"; return 1; }
        # A server that lists models must list this one; one that lists none is taken at its word.
        if printf '%s' "$models" | jq -e '(.data // []) | length > 0' >/dev/null 2>&1 \
           && ! printf '%s' "$models" | jq -e --arg m "$LOCAL_MODEL" '.data | any(.id == $m)' >/dev/null 2>&1; then
          echo "local seat selected but $LOCAL_BASE_URL does not serve $LOCAL_MODEL"; return 1
        fi
      else
        [ -x "$CLAUDE" ] || { echo "local seat selected but no claude binary at $CLAUDE"; return 1; }
        curl -fsS -m 5 "$LOCAL_URL/api/tags" 2>/dev/null | grep -q "\"$LOCAL_MODEL" \
          || { echo "local seat selected but $LOCAL_URL does not serve $LOCAL_MODEL"; return 1; }
      fi ;;
    grok)   [ -x "$GROK" ] || { echo "grok seat selected but no binary at $GROK (install: curl -fsSL https://x.ai/cli/install.sh | bash)"; return 1; }
            command -v jq >/dev/null 2>&1 \
              || { echo "grok seat selected but jq is missing (needed to read its result)"; return 1; } ;;
    api)    [ -x "$TASKJSON" ] || { echo "api seat selected but conveyor-taskjson is missing at $TASKJSON"; return 1; }
            # Planner/critic only: it has no tools, so it cannot build or verify.
            [ -n "${CONVEYOR_API_BASE_URL:-}${CONVEYOR_PLANNER_API_BASE_URL:-}${CONVEYOR_CRITIC_API_BASE_URL:-}" ] \
              || { echo "api seat selected but CONVEYOR_API_BASE_URL is not set"; return 1; }
            [ -n "${CONVEYOR_API_MODEL:-}${CONVEYOR_PLANNER_API_MODEL:-}${CONVEYOR_CRITIC_API_MODEL:-}" ] \
              || { echo "api seat selected but CONVEYOR_API_MODEL is not set"; return 1; } ;;
    *) echo "unknown seat '$1' (want claude|gemini|codex|grok|local|api)"; return 1 ;;
  esac
}

state_file() { printf '%s/%s.%s' "$LOGS" "${task%.md}" "$1"; }

get_legs() { # prints the counter, or 0
  local n
  n=$(sed -n 's/^## Legs: \([0-9]\{1,\}\)$/\1/p' "$taskpath" | head -1)
  printf '%s' "${n:-0}"
}

# Is the counter PRESENT? Deliberately not "is it nonzero". reset_legs leaves
# "## Legs: 0" in the file, so a requeued dead-end task has a counter whose
# VALUE is 0 — and branching bump_legs on the value sent it down the INSERT
# path, where the existing "## Legs: 0" line matched the /^## / insertion
# anchor and became its own anchor. The result was two contradictory counters
# in the one file this slice designates as the loss record. Presence is the
# question the branch was always asking; value never was.
has_legs() { grep -q '^## Legs: [0-9]\{1,\}$' "$taskpath"; }

# Spend one leg. Called immediately BEFORE a seat is invoked, so a leg that
# times out still counts — otherwise a task that hangs every seat would never
# reach the ceiling. The one refund is seat_crash(): a seat PROCESS that exits
# nonzero (usage limit, auth, binary gone) never ran the task at all.
bump_legs() {
  local cur new tmp
  cur=$(get_legs); new=$((cur + 1))
  tmp="$taskpath.legs.$$"
  if has_legs; then
    # Rewrite the first counter and DROP any others, so a file that somehow
    # already carries duplicates heals on its next leg instead of compounding.
    awk -v n="$new" '
      /^## Legs: [0-9]+$/ { if (d) next; print "## Legs: " n; d = 1; next }
      { print }' "$taskpath" > "$tmp" \
      || die "leg counter bump failed for $task"
  else
    # Insert before the first "## " heading (usually ## Checklist) so it reads
    # as header matter; fall back to the end for a task with no headings.
    awk -v line="## Legs: $new" '
      /^## / && !d { print line; print ""; d = 1 }
      { print }
      END { if (!d) { print ""; print line } }' "$taskpath" > "$tmp" \
      || die "leg counter insert failed for $task"
  fi
  cat "$tmp" > "$taskpath" || die "leg counter write failed for $task"
  rm -f "$tmp"
  legspent=$new
}

# Reset the counter on a dead end so a task the operator loops back in does not trip
# the ceiling on its first bounce. The count is not lost — the "## Dead End"
# block records it in words. The counter is runner bookkeeping, not content,
# so this is not a breach of the append-only rule that governs the checklist.
reset_legs() {
  local tmp="$taskpath.legs.$$"
  awk '/^## Legs: [0-9]+$/ { if (d) next; print "## Legs: 0"; d = 1; next }
       { print }' \
    "$taskpath" > "$tmp" || die "leg counter reset failed for $task"
  cat "$tmp" > "$taskpath" || die "leg counter reset write failed for $task"
  rm -f "$tmp"
}

# The checklist's shape at driver-leg start: what steps exist, which are
# ticked. `--list` runs no commands — this is a question about the file.
capture_baseline() {
  "$CHECK" --list "$taskpath" > "$(state_file baseline)" 2>/dev/null \
    || die "baseline capture failed for $task"
}

# 0 = the round trip moved: at least one NEW tick or at least one NEW step.
made_progress() {
  local base cur line claim
  base=$(state_file baseline)
  [ -s "$base" ] || return 0   # no baseline → never flag on ignorance
  cur=$("$CHECK" --list "$taskpath" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    claim=${line:4}
    grep -qxF "[x] $claim" "$base" || grep -qxF "[ ] $claim" "$base" \
      || return 0              # a step that did not exist at the baseline
    case "$line" in
      "[x] "*) grep -qxF "[x] $claim" "$base" || return 0 ;;  # newly ticked
    esac
  done <<< "$cur"
  return 1
}

# The verifier's vocabulary is "REFUTED: <claim> — <evidence>"
# (verifier-preamble.md). The evidence differs every leg, so the KEY is the
# claim half only, normalized. Deliberately NOT keyed to conveyor-check's own
# FAIL lines: a step that simply is not done yet is what rule 1 measures, and
# double-counting it here would flag ordinary work.
record_refuted() { # logfile
  local keys
  keys=$(grep -E '^REFUTED: ' "$1" 2>/dev/null \
    | sed -e 's/^REFUTED: //' -e 's/ — .*$//' \
          -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' \
    | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u)
  [ -n "$keys" ] || return 0
  printf '%s\n' "$keys" >> "$(state_file refuted)" \
    || die "refuted-tally append failed for $task"
}

# Prints the key and returns 0 if any claim has been refuted twice or more.
# `sort -u` above means one leg can only ever contribute one count per claim,
# so two counts really are two separate seats saying the same thing.
refuted_twice() {
  local f k
  f=$(state_file refuted)
  [ -f "$f" ] || return 1
  k=$(sort "$f" | uniq -c | awk '$1 >= 2 { sub(/^ *[0-9]+ +/, ""); print; exit }')
  [ -n "$k" ] || return 1
  printf '%s' "$k"
}

# Same payload shape as drain-intents.py; the API dedupes on itemRef, so a
# task that lands in human/ twice mints one intent, not two.
mint_intent() { # task label [body]
  # $3 is the ASK IN FULL. The label is a 100-char headline and the dashboard
  # stored nothing else until 2026-09-02, so a human step longer than that
  # reached the operator cut mid-sentence — twice reported by him, 09-01 and 09-02.
  # The body is optional: an older dashboard ignores the extra field.
  local payload
  payload=$(jq -nc --arg ref "$REF_PREFIX$1" --arg lbl "$2" --arg body "${3:-}" \
    '{kind:"flag", itemRef:$ref, itemLabel:$lbl, action:"work",
      createdBy:"conveyor"} + (if $body == "" then {} else {body:$body} end)') || return 1
  # Standalone: no dashboard queue to POST to, so the ask is appended to a
  # local inbox instead. The contract is unchanged — a human gate is still
  # recorded somewhere BEFORE the task is parked, and a write that fails still
  # returns nonzero so the belt breaks loudly rather than parking silently.
  if [ "${CONVEYOR_STANDALONE:-0}" = "1" ]; then
    mkdir -p "$LOGS" || return 1
    printf '%s\n' "$payload" >> "$LOGS/human-inbox.jsonl" || return 1
    # CONVEYOR_INTENTS_ALSO=1 (2026-10-25): the :4200 dashboard is back on
    # the author's server while the author's notify sender and the the author's database receipts are not, so
    # standalone stays declared and the ask ALSO goes to the operator's queue, where
    # conveyor-tap reads it. The inbox line above is the guarantee; a failed
    # POST is logged to notify.log, never fatal.
    if [ "${CONVEYOR_INTENTS_ALSO:-0}" = "1" ]; then
      curl -sf -m 10 -H 'Content-Type: application/json' \
        -d "$payload" "$INTENTS_URL" >/dev/null \
        || printf '[%s] intent POST to %s failed for %s\n' "$(date -Is)" "$INTENTS_URL" "$1" >> "$LOGS/notify.log"
    fi
    return 0
  fi
  curl -sf -m 10 -H 'Content-Type: application/json' \
    -d "$payload" "$INTENTS_URL" >/dev/null
}

# Run conveyor-check on $taskpath; sets $checkout/$crc, appends to $log.
run_check() { # label
  checkout="$("$CHECK" "$taskpath" 2>&1)"; crc=$?
  printf -- '\n--- conveyor-check (%s) ---\n%s\n' "$1" "$checkout" \
    >> "$log" || die "log append failed for $task"
}

# TASK FILES IN AND OUT (2026-10-26). Each task has an output folder for its
# deliverables and may carry attachments (input files conveyor-add copied in).
# conveyor-check --io names them -- the checker is the one reader of the task
# file -- and every seat leg gets them exported (the checker sets the same
# three for verify commands) and named at the end of its prompt, so a task
# written before this existed still gets a folder. The folder is created here;
# a seat should not have to.
task_io() {
  local kv
  unset CONVEYOR_TASK_ID CONVEYOR_OUTPUTS CONVEYOR_ATTACHMENTS
  while IFS= read -r kv; do
    case "$kv" in
      CONVEYOR_TASK_ID=*|CONVEYOR_OUTPUTS=*|CONVEYOR_ATTACHMENTS=*) export "$kv" ;;
    esac
  done < <("$CHECK" --io "$taskpath" 2>/dev/null)
  if [ -n "${CONVEYOR_OUTPUTS:-}" ]; then mkdir -p "$CONVEYOR_OUTPUTS" 2>/dev/null || true; fi
}
io_note() {
  [ -n "${CONVEYOR_OUTPUTS:-}" ] || return 0
  printf '
OUTPUT FOLDER (save this task'"'"'s deliverables here; it exists; also $CONVEYOR_OUTPUTS): %s
' "$CONVEYOR_OUTPUTS"
  if [ -d "${CONVEYOR_ATTACHMENTS:-}" ]; then
    printf 'ATTACHMENTS FOLDER (input files: read them, never modify, move or delete them): %s
' "$CONVEYOR_ATTACHMENTS"
  fi
}

# Append a "## Leg N — <seat>" block to the task file. Append-only: the
# runner never rewrites what a leg wrote before it.
append_leg() { # seat body
  local leg
  leg=$(( $(grep -cE '^## Leg [0-9]+' "$taskpath") + 1 ))
  {
    printf '\n## Leg %d — %s\n\n' "$leg" "$1"
    printf '%s\n' "$2"
  } >> "$taskpath" || die "task-file append failed for $task"
}

# A SEAT'S TICK CANNOT MATTER (2026-09-04). Called after EVERY seat leg
# (driver, spec, verifier) and BEFORE the post-leg conveyor-check, so the only
# ticks a task file ever carries are the CHECKER's (command steps) and
# conveyor-tap's (HUMAN steps). Two holes it closes, one harmless-looking and
# one not:
#   - a hand-tick on a COMMAND step never changed routing (run_check re-verifies
#     every one of them) but it SURVIVED in the file, so the verifier seat read
#     it, went to the transcript, and failed the task on process — cash-gap,
#     2026-09-04 20:41, leg 1: "REFUTED: Checker-only ticking". A build leg and
#     a verify leg spent on a mark the code had already made irrelevant. And the
#     rule the driver broke lived in verifier-preamble.md and NOWHERE in the
#     driver's own preamble: it was never told.
#   - a hand-tick on a HUMAN step was never revoked ANYWHERE. conveyor-check's
#     check mode leaves them alone by design, so a driver writing `[x]` on
#     `the operator confirms this spec :: verify: HUMAN` forged the human gate: every
#     step reads ticked, route_done sends the task to verify/ and then done/, on
#     a ruling the operator never made. Only conveyor-tap sets a HUMAN tick and it does
#     so BETWEEN legs, so a HUMAN tick that appeared DURING one is a forgery.
#   - and the sibling of that, closed 2026-09-05: a seat that DELETES the
#     `verify: HUMAN` step instead of ticking it. Measured against the live
#     runner by the verifier leg that refused this task's first build — the
#     task reached verify/ with the gate simply gone and ZERO intents minted,
#     because rewriting tick characters only touches steps still present and
#     made_progress iterates the CURRENT steps. --erase now reinstates every
#     step in the snapshot that is missing from the file, at its snapshot
#     position with its snapshot tick, so a deleted gate comes back unticked
#     and parks the task on the operator.
#   - and the third of the same family: a seat that DOWNGRADES the gate,
#     `:: verify: HUMAN` → `:: verify: true`. The claim survives, so it is
#     neither a hand-tick nor a deletion — the CHECKER ticks it, and the task
#     files itself. A HUMAN step's kind is pinned; it comes back whole.
# RESTORE-TO-BASELINE, not untick-all, and the difference is load-bearing: the
# verifier-fail and dead-end paths run NO check afterwards, and route_bounce's
# progress rule (made_progress) reads the ticks in the file — unticking every
# command step there would make a moving task read as a zero-progress round
# trip and dead-end it. Wherever a check does follow, the two are identical,
# since it re-verifies every command step regardless. The baseline is the
# pre-leg snapshot the crash path already takes (state_file prebump); a missing
# one means this leg cannot know what was ticked before it, and never flagging
# on ignorance is the same rule made_progress follows.
# The parse lives in conveyor-check --erase, not in a sed here: a THIRD reader
# of the checklist grammar is what conveyor-check's --list comment exists to
# prevent. On record, costs no leg: one line under a "## Leg N — hand ticks"
# heading (append_leg numbers BLOCKS written, not seats spent, so nothing is
# charged) and the per-step detail into the leg log.
erase_hand_ticks() {
  local snap out cmd_n human_n back_n miss_n kind_n up_n note
  snap="$(state_file prebump)"
  [ -s "$snap" ] || return 0
  out=$("$CHECK" --erase "$taskpath" "$snap" 2>&1) \
    || die "hand-tick erase failed for $task: $out"
  [ -n "$out" ] || return 0   # the seat left the ticks alone: nothing to say
  cmd_n=$(printf '%s\n' "$out" | grep -c '^ERASED command ' || true)
  human_n=$(printf '%s\n' "$out" | grep -c '^ERASED HUMAN ' || true)
  back_n=$(printf '%s\n' "$out" | grep -c '^RESTORED ' || true)
  note=""
  [ "$cmd_n" -gt 0 ] && note="$(step_count "$cmd_n" command)"
  if [ "$human_n" -gt 0 ]; then
    [ -n "$note" ] && note="$note, "
    note="$note$(step_count "$human_n" HUMAN) (forgery)"
  fi
  [ -n "$note" ] && note="hand-ticks erased: $note"
  if [ "$back_n" -gt 0 ]; then
    [ -n "$note" ] && note="$note; "
    note="$note$back_n tick(s) the seat removed restored"
  fi
  # The DELETION route (2026-09-05), the tick route's sibling: a seat that
  # removes a `verify: HUMAN` step bypasses the operator exactly as a forged tick did.
  # conveyor-check --erase puts it back; this is that on the record.
  miss_n=$(printf '%s\n' "$out" | grep -c '^RESTORED_MISSING \(HUMAN\|command\) ' || true)
  if [ "$miss_n" -gt 0 ]; then
    [ -n "$note" ] && note="$note; "
    if [ "$miss_n" -eq 1 ]; then note="${note}1 step the seat deleted restored"
    else note="${note}$miss_n steps the seat deleted restored"; fi
  fi
  # And the third route: `:: verify: HUMAN` rewritten to `:: verify: true`.
  # The claim survives, so the step is not "missing" and not hand-ticked — the
  # CHECKER ticks it, which is why this one needs its own line.
  kind_n=$(printf '%s\n' "$out" | grep -c '^RESTORED_KIND HUMAN ' || true)
  if [ "$kind_n" -gt 0 ]; then
    [ -n "$note" ] && note="$note; "
    if [ "$kind_n" -eq 1 ]; then note="${note}1 HUMAN gate the seat downgraded restored"
    else note="${note}$kind_n HUMAN gates the seat downgraded restored"; fi
  fi
  # The FOURTH route, the third one's mirror: an ALREADY-TICKED command step
  # rewritten UP to `:: verify: HUMAN`. Nothing was hand-ticked (the tick came
  # from a previous leg's checker) and nothing was deleted, so this route was
  # silent in every count above — and it is the worst of the four, because the
  # HUMAN box arrives already ticked and route_done only looks for unticked
  # ones. Its own line for the same reason the downgrade has one.
  up_n=$(printf '%s\n' "$out" | grep -c '^RESTORED_KIND command ' || true)
  if [ "$up_n" -gt 0 ]; then
    [ -n "$note" ] && note="$note; "
    if [ "$up_n" -eq 1 ]; then note="${note}1 command step the seat rewrote to HUMAN reinstated"
    else note="${note}$up_n command steps the seat rewrote to HUMAN reinstated"; fi
  fi
  # Something changed but none of the counted classes did (a restored
  # `## Checklist` heading on its own). An empty note under a leg heading is a
  # block that says nothing happened while the file says otherwise.
  [ -n "$note" ] || note="checklist restored to its pre-leg state"
  printf -- '\n--- erase_hand_ticks ---\n%s\n%s\n' "$note" "$out" \
    >> "$log" || die "log append failed for $task"
  append_leg "hand ticks" "$note"
}
step_count() { # n kind
  [ "$1" -eq 1 ] && printf '%s %s step' "$1" "$2" || printf '%s %s steps' "$1" "$2"
}

# Stage to human/ + mint one proposed intent. $checkout must be current.
route_human() { # verdict-name
  move "$taskpath" "$HUMAN/$task"
  verdict=$1
  local steps label body
  steps=$(printf '%s\n' "$checkout" \
    | sed -n 's/^\[ \] HUMAN //p' | paste -sd'; ' -)
  # ASK FIRST, FILE LAST. The label is capped at 100 chars and the task
  # filename is ~58 of them (timestamp + slug + .md), so leading with $task
  # spent 58% of the card on the one part the operator already knows and truncated
  # the only part he needs. the operator, 2026-09-01, reading his own dashboard:
  # "waiting on me on the dashboard is cut off". The slug is trimmed of its
  # timestamp and extension for the same reason — it identifies, it does not
  # need to be exact; the full name is in the receipt and the task file.
  label="HUMAN: $steps — ${task#*-*-}"; label="${label%.md}"
  # The body carries every step in full, one per line, plus the task file that
  # holds the reasoning. Uncapped on purpose — this is the copy he reads.
  #
  # WHAT THE ASK NEEDS AROUND IT (2026-09-03). Until today the body was the
  # HUMAN steps and a filename, which is the ask with all of its context
  # stripped: it never said what the task WAS, and it never said what the belt
  # had already settled. the operator, reading the phone-grader card: "can you add
  # more of the explanation in the dashboard its cut off". A ruling needs three
  # things — what this is about, what is already proven so he is not re-deciding
  # machine-checkable facts, and what is actually left to him. The title comes
  # from the task's own first heading (his words when he queued it, or the
  # emitter's), the proven list from the same checkout the steps come from, and
  # the leg count says how much work is standing behind the question.
  local title proven legs
  title=$(sed -n '1s/^#[[:space:]]*//p' "$HUMAN/$task")
  proven=$(printf '%s\n' "$checkout" | sed -n 's/^\[x\] PASS[[:space:]]*/- /p')
  legs=$(grep -cE '^## Leg [0-9]+' "$HUMAN/$task" 2>/dev/null || echo 0)
  body="${title:-$task}

WHAT YOU DECIDE
$(printf '%s\n' "$checkout" | sed -n 's/^\[ \] HUMAN[[:space:]]*/- /p')"
  if [ -n "$proven" ]; then
    body="$body

ALREADY PROVEN BY THE BELT — do not re-decide these
$proven"
  fi
  body="$body

$legs leg(s) spent. Full reasoning, every leg, in the task file:
$HUMAN/$task"
  mint_intent "$task" "${label:0:100}" "$body" \
    || { verdict=$1-intent-failed; mint_failed=1; }
}

# A dead end: the loss is kept, and it is surfaced four ways. The task file
# already holds every "why" any leg wrote — that file IS the loss record, so
# it moves to failed/ whole rather than being summarized anywhere.
dead_end() { # reason
  local reason="$1" lastverdict body msg
  lastverdict=$(grep -E '^(VERDICT|RESULT): ' "$log" 2>/dev/null | tail -1)
  [ -n "$lastverdict" ] || lastverdict="(no VERDICT/RESULT line in the last log)"
  # The retry half is $RETRY_FMT (see the standalone block): who can act on
  # this loss, and how, is the one thing that differs between the author's box
  # and a stranger's. Everything before it is identical either way.
  body=$(printf 'Reason: %s\nLegs spent this attempt: %s\nLast verdict: %s\nLast log: %s\n\nForward progress was silent by design; this is the stop. The full leg and\nverdict history above is the loss record - nothing here has been summarized\naway. %s' \
    "$reason" "$(get_legs)" "$lastverdict" "$log" "$(printf "$RETRY_FMT" "$task")")
  {
    printf '\n## Dead End — %s\n\n' "$(date -Is)"
    printf '%s\n' "$body"
  } >> "$taskpath" || die "dead-end append failed for $task"
  reset_legs
  move "$taskpath" "$FAILED/$task"
  verdict=dead-end
  close_pending=failed

  # Each surfacing step is attempted even if an earlier one failed — a dead
  # end that reaches one channel is better than one that reaches none — and
  # every failure is remembered so the belt reports itself broken afterwards.
  # Capped at 100 like route_human and the dashboard's other producers. The
  # API does not enforce it (item_label is TEXT and createIntent validates only
  # presence), so this is about the card being readable on a phone — the full
  # reason survives in the task file, the notify and the reminder row, which
  # are where it is actually read. Every dead-end reason names its rule inside
  # the first few words, so the truncation never hides WHICH rule fired.
  # Same ordering fix as route_human: the rule that fired is the payload,
  # the filename is the envelope. Truncation should eat the envelope.
  local label="DEAD END: ${reason} — ${task#*-*-}"; label="${label%.md}"
  mint_intent "$task:dead-end" "${label:0:100}" "${reason}

task: $task" \
    || { mint_failed=1; surface_failed="$surface_failed intent"; }

  # The notify names the buttons because they now exist: conveyor-tap services
  # :dead-end refs (2026-09-05) and the dashboard card carries its own verbs.
  # It said the opposite while the door was shut, for the same reason — a
  # notify must not promise what a tap cannot do, and must not withhold what it
  # can.
  msg=$(printf 'conveyor DEAD END @%s: %s\n%s\n%s\nTask kept whole in failed/%s. %s' \
    "$BELT_HOST" "$task" "$reason" "$lastverdict" "$task" "$RETRY_LINE")
  if ! "$NOTIFY" --b64 "$(printf '%s' "$msg" | base64 -w0)" >/dev/null 2>&1; then
    surface_failed="$surface_failed notify"
  fi

  if ! "$YGG" "$task" "$reason" "$lastverdict" "$FAILED/$task" >/dev/null 2>&1; then
    surface_failed="$surface_failed receipt"
  fi

  # The tally is the runner's, not the task's — clear it so a requeue is
  # judged on its own legs. The lessons live in the task file.
  rm -f "$(state_file refuted)" "$(state_file baseline)" "$(state_file prebump)" \
    "$(state_file steptries)" "$(state_file escalated)" "$(state_file escalate-next)" \
    "$(state_file planstart)" "$(state_file plansteps)"
}

# ---- Seat crash ---------------------------------------------------------------
# See "A SEAT CRASH IS NOT A TASK OUTCOME" in the header. One incident = one
# notify + one nonzero exit; the state file is the incident.
SEAT_CRASH_STATE="$LOGS/seat-crash.notified"

# BACKOFF (2026-09-04, from a measured loss): the incident above deduped the
# NOTIFY and nobody gave the RETRY the same treatment, so a belt with no
# working seat kept handing out a leg every 5 minutes. On 09-04 that spent the
# ChatGPT plan to usage_limit_exceeded, the seat was moved to claude, and the
# claude session limit went the same way -- 21 legs on one task between 21:20
# and 23:03, every one of them a quota error, one alert. A dead seat must cost
# less each tick, not the same forever. Two fields: attempts, next-attempt
# epoch. Deliberately a SEPARATE file from SEAT_CRASH_STATE so the incident's
# open-time and its one-notify semantics are untouched.
SEAT_BACKOFF_STATE="$LOGS/seat-crash.backoff"

# 5 min doubling to a 1 h ceiling: 10, 20, 40, 60, 60... A session limit resets
# on the hour, so an hour is the longest wait that can still be wrong by less
# than one reset window.
backoff_arm() {
  local attempts=0 delay
  [ -s "$SEAT_BACKOFF_STATE" ] && attempts=$(awk '{print $1+0}' "$SEAT_BACKOFF_STATE" 2>/dev/null)
  attempts=$((attempts + 1))
  delay=$((300 * (1 << (attempts < 5 ? attempts : 5))))
  [ "$delay" -gt 3600 ] && delay=3600
  printf '%s %s\n' "$attempts" "$(( $(date +%s) + delay ))" > "$SEAT_BACKOFF_STATE" \
    || echo "conveyor: backoff state write failed (belt will retry next tick)" >&2
  echo "conveyor: seat backoff armed -- attempt $attempts, next leg in $((delay / 60))m" >&2
}

# Is the belt still serving its backoff? Prints why and returns 0 if so.
# A missing or unreadable file reads as NOT backed off: the failure that
# matters here is a belt stuck off, and a broken state file must not be the
# thing that stops the work.
backoff_holding() {
  local until now
  [ -s "$SEAT_BACKOFF_STATE" ] || return 1
  until=$(awk '{print $2+0}' "$SEAT_BACKOFF_STATE" 2>/dev/null) || return 1
  [ "${until:-0}" -gt 0 ] || return 1
  now=$(date +%s)
  [ "$now" -lt "$until" ] || return 1
  echo "conveyor: no working seat -- backoff holding, next leg at $(date -d "@$until" -Is 2>/dev/null || echo "$until"). No leg spent." >&2
  return 0
}

# The most telling line of a seat that exited nonzero. A codex seat writes its
# failure as a `turn.failed` event in the raw JSONL beside the log (the 20:57
# loss: "You've hit your usage limit..."); a claude seat writes stderr into the
# log itself. Fall through to the last non-blank line so the note is never empty.
seat_error_line() { # log
  local raw="${1%.log}.jsonl" line=""
  if [ -s "$raw" ] && command -v jq >/dev/null 2>&1; then
    # turn.failed is codex; "error" is grok's documented failure object, and an
    # is_error result is how a stream-json seat (claude, grok) reports one.
    line=$(jq -r '(select(.type == "turn.failed") | .error.message // empty),
                  (select(.type == "error") | .message // empty),
                  (select(.type == "result" and .is_error == true) | .result // empty)' "$raw" 2>/dev/null | tail -1)
  fi
  [ -n "$line" ] || line=$(grep -iE 'usage.?limit|rate.?limit|error|fail|denied|unauthori|quota' "$1" 2>/dev/null | tail -1)
  [ -n "$line" ] || line=$(awk 'NF {last=$0} END {print last}' "$1" 2>/dev/null)
  printf '%s' "${line:-(seat wrote nothing)}"
}

# Snapshot the task file BEFORE bump_legs so a crash can put it back exactly.
snapshot_prebump() {
  cat "$taskpath" > "$(state_file prebump)" || die "pre-leg snapshot failed for $task"
}

# rc back-dir seat-name. Sets $verdict, $legspent, $seat_crash_fresh; may add
# to $surface_failed. Never dies on the crash itself — a dead seat is reported,
# not compounded.
seat_crash() {
  local why msg
  why=$(seat_error_line "$log")
  # Refund: the pre-leg bytes come back, so "## Legs:" and everything else read
  # as if this tick had not happened — except for the note that says it did.
  cat "$(state_file prebump)" > "$taskpath" || die "task restore failed for $task"
  legspent=$(get_legs)
  append_leg "seat crash" "$(printf 'Seat (%s) exited %s at %s before it could answer. This is the belt being unable to run, not a task outcome: no leg charged, task returned to %s/ as it was, and the belt now BACKS OFF (5 min doubling to 1 h) instead of retrying every tick. Error line:\n\n    %s\n\nTranscript: %s' \
    "$3" "$1" "$(date -Is)" "$(basename "$2")" "$why" "$log")"
  move "$taskpath" "$2/$task"
  verdict=seat-crash
  backoff_arm
  if [ -e "$SEAT_CRASH_STATE" ]; then
    seat_crash_fresh=0
    echo "conveyor: seat still down ($3 exited $1 on $task; incident opened $(cat "$SEAT_CRASH_STATE")) — notify suppressed until a seat returns 0" >&2
  else
    seat_crash_fresh=1
    date -Is > "$SEAT_CRASH_STATE" || die "seat-crash state write failed"
    msg=$(printf 'conveyor SEAT CRASH @%s: the belt has no working seat (%s exited %s).\n%s\nTask %s is back in %s/ untouched, no leg charged. The belt backs off (5 min doubling to a 1 h ceiling) until a seat returns 0 -- both this alert AND the retry, not just the alert.' \
      "$BELT_HOST" "$3" "$1" "$why" "$task" "$(basename "$2")")
    if ! "$NOTIFY" --b64 "$(printf '%s' "$msg" | base64 -w0)" >/dev/null 2>&1; then
      surface_failed="$surface_failed notify"
    fi
  fi
}

# The runner's last word on a leg that hit a seat crash: nonzero only on the
# tick that opened the incident (see the header for why not every tick).
seat_crash_exit() {
  [ "${seat_crash_fresh:-0}" -eq 1 ] \
    && die "SEAT CRASH: the belt has no working seat (rc $rc on $task) — $HUMAN_REF notified, task requeued, will retry each tick"
  return 0
}

# Every return to queue/ passes through here. It is the ONLY place the stop
# rule is evaluated, so there is one answer to "why did this stop", not four.
# $1 = 1 only when a verify leg just ran, i.e. a driver+verify round trip
# actually completed (see the header note on which bounces count).
route_bounce() { # round-trip(0|1)
  local reason="" legs k
  legs=$(get_legs)
  if [ "$legs" -ge "$LEG_CEILING" ]; then
    reason="leg ceiling — $legs legs spent (backstop is $LEG_CEILING)"
  elif [ "$1" -eq 1 ]; then
    if k=$(refuted_twice); then
      reason="same step REFUTED twice — \"$k\""
    elif ! made_progress; then
      reason="zero-progress round trip — driver+verify ticked no new box and discovered no new step"
    fi
  fi
  if [ -n "$reason" ]; then
    dead_end "$reason"
  else
    move "$taskpath" "$QUEUE/$task"
  fi
}

# ---- Spec leg -----------------------------------------------------------------
# Is the task file in the shape the spec seat was told to leave it in? Prints
# the reason on failure. The HUMAN count is the load-bearing rule: conveyor-tap
# ticks EVERY unticked HUMAN box on approve, so a spec that carries two would
# have its second one ruled on by a tap that never saw it.
spec_shape_ok() {
  grep -q '^## Spec' "$taskpath" || { echo "no '## Spec' section"; return 1; }
  grep -q '^## Checklist' "$taskpath" || { echo "no '## Checklist' section"; return 1; }
  local counts human cmd
  counts=$("$CHECK" --list-json "$taskpath" 2>/dev/null | python3 -c '
import sys, json
h = c = 0
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    s = json.loads(line)
    if s["human"]: h += 1
    else: c += 1
print(h, c)') || { echo "checklist unparseable"; return 1; }
  human=${counts% *}; cmd=${counts#* }
  [ "$cmd" -ge 1 ] || { echo "no command step — every step after the first must be a verify: <command>"; return 1; }
  [ "$human" -eq 1 ] || { echo "$human HUMAN steps — exactly one is allowed (the spec confirmation)"; return 1; }
  return 0
}

# A REJECTED spec must not survive as a checklist. Leg type is decided by
# `grep -q '^## Checklist'`, so a malformed spec left in place would make the
# NEXT leg a driver leg — it would build against a checklist the operator never
# confirmed, which is the exact build-before-ruling this seat exists to stop.
# So everything from the first `## Spec` / `## Checklist` line to EOF is cut
# out of the file and handed back to the caller, who writes it INTO the leg
# note (nothing is lost — the task file is the loss record). Quoted with `> `
# on every line: conveyor-check's STEP_RE allows leading whitespace, so mere
# indentation would still parse the dead steps, and `^## ` would still match.
# Sets $quarantined (may be empty). The file ends in no-checklist shape.
spec_quarantine() {
  local cut tmp
  cut=$(grep -nE '^## (Spec|Checklist)' "$taskpath" | head -1 | cut -d: -f1)
  quarantined=""
  [ -n "$cut" ] || return 0
  quarantined=$(tail -n +"$cut" "$taskpath" | sed 's/^/> /')
  tmp="$taskpath.q.$$"
  head -n $((cut - 1)) "$taskpath" > "$tmp" || die "spec quarantine failed for $task"
  cat "$tmp" > "$taskpath" || die "spec quarantine write failed for $task"
  rm -f "$tmp"
}

# The leg note for every spec ending that is not accepted: the why, then the
# rejected text quoted beneath it so the next spec seat can read what went
# wrong without it being live.
spec_bounce() { # verdict why
  spec_quarantine
  local note
  note=$(printf '%s' "$2")
  [ -n "$quarantined" ] && note=$(printf '%s\n\nREJECTED SPEC, quarantined here so it cannot be built against (quoted, not live):\n\n%s' "$note" "$quarantined")
  append_leg spec "$note"
  verdict=$1; route_bounce 0
}

# Park a validated spec for the operator. Ref carries a :spec suffix ON PURPOSE:
# conveyor-tap PATCHes an approved intent to `dispatched`, which the dashboard
# counts as OPEN, and createIntent() returns the existing open row (200,
# created:false) for a repeat of the same identity. So if this used the bare
# `conveyor:<task>` ref, a later HUMAN park of the same task (a verifier-
# appended judgment step) would mint nothing and the operator would never see the
# card — curl -sf would call that success. Distinct ref, distinct identity.
route_spec() {
  move "$taskpath" "$HUMAN/$task"
  verdict=spec-wait
  local title spec label body
  title=$(sed -n '1s/^#[[:space:]]*//p' "$HUMAN/$task")
  # The spec block, from its heading to the checklist heading, exclusive.
  spec=$(awk '/^## Spec/{f=1; next} /^## Checklist/{f=0} f' "$HUMAN/$task")
  # ASK FIRST, FILE LAST (route_human's rule): the label is what the card shows.
  label="SPEC: ${title:-$task}"
  body="THE BELT READ YOUR TASK AND THIS IS ITS UNDERSTANDING. Nothing has been
built. Approve = build exactly this. Dismiss = wrong reading; requeue it with
more words.

${spec}

CHECKLIST IT WILL BE HELD TO
$(sed -n '/^## Checklist/,$p' "$HUMAN/$task" | grep -E '^- \[' )

Task file, with every leg's reasoning:
$HUMAN/$task"
  mint_intent "$task:spec" "${label:0:100}" "$body" \
    || { verdict=spec-wait-intent-failed; mint_failed=1; }
}

# Routing after a driver leg's RESULT: done — the commands are the gate,
# not the model's claim. Sets $verdict; may set $mint_failed.
route_done() {
  if ! grep -q '^## Checklist' "$taskpath"; then
    # Unreachable from a driver leg (a driver leg requires a checklist) and
    # defended anyway: a no-checklist task NEVER files as done on a claim.
    spec_bounce spec-ignored "$(printf 'A leg claimed RESULT: done on a task with no checklist at %s (log: %s). Nothing files as done on a claim; back to queue/ for a spec leg.' \
      "$(date -Is)" "$log")"
    return
  fi
  run_check "driver leg end"
  if [ $crc -eq 0 ]; then
    # All non-HUMAN steps proved. HUMAN detection reads the CHECKER's
    # output, not a second parse of the grammar — one grammar, one parser.
    if printf '%s\n' "$checkout" | grep -q '^\[ \] HUMAN '; then
      route_human human-wait
    else
      move "$taskpath" "$VERIFY/$task"; verdict=check-pass
    fi
  elif [ $crc -eq 1 ]; then
    # Unticked non-HUMAN steps: the why goes INTO the task, then back on
    # the belt.
    append_leg driver "$(printf 'Leg claimed RESULT: done at %s (log: %s); conveyor-check refuted it:\n\n```\n%s\n```' \
      "$(date -Is)" "$log" "$checkout")"
    # Ceiling only: half a round trip is not a round trip (header note).
    # A planned task also counts tries per step (step_tries, SPEC-planning.md).
    verdict=check-fail
    if is_planned && step_tries; then :; else route_bounce 0; fi
  else
    # Checker itself errored (exit 2 = usage/IO) — task can't be judged.
    move "$taskpath" "$FAILED/$task"; verdict=check-error
  fi
}

# Routing after a driver leg's RESULT: blocked. Sets $verdict; may set
# $mint_failed / $surface_failed.
#
# A BLOCK THAT IS ONLY WAITING ON THE PERSON IS A QUESTION, NOT A LOSS
# (2026-10-26). The shape that exposed it: every command step passes, the one
# open step is `verify: HUMAN` (for example a fresh one a verifier appended
# after refusing a tick it could not trust), and the executor says, correctly,
# "RESULT: blocked — waiting on the operator". Until now that went to
# dead_end, i.e. failed/ — and the app's Dead ends tray has no Approve button,
# while a retry from failed/ only hands it to another driver leg that can
# never tick a HUMAN box. So the person's yes, the one thing the task needed,
# had nowhere to land. route_human is that place: human/ ("Needs you" in the
# app), where the existing Approve button ticks the step and puts the task
# back in queue/, exactly as for any other HUMAN gate.
#
# The checker decides, not the seat's claim: only when conveyor-check shows
# every command step passing AND at least one HUMAN step open. Anything else
# (a failing command step, a checker error, nothing open) is the BLOCKED dead
# end it always was. The seat's words go into the task file first so the
# person can read why it stopped. No AI can approve: erase_hand_ticks has
# already run for this leg, and only the person's button ticks a HUMAN box.
route_blocked() { # final-line
  local why
  why=$(printf '%s' "$1" | sed -E 's/^RESULT: blocked[[:space:]]*[—:-]*[[:space:]]*//' | cut -c1-120)
  if grep -q '^## Checklist' "$taskpath"; then
    run_check "driver leg end (blocked)"
    if [ $crc -eq 0 ] && printf '%s\n' "$checkout" | grep -q '^\[ \] HUMAN '; then
      append_leg driver "$(printf 'Seat reported BLOCKED at %s (log: %s): %s\n\nconveyor-check: every command step passes and the only open step(s) are verify: HUMAN, so this is waiting on %s, not a dead end. Parked in human/ for their yes.' \
        "$(date -Is)" "$log" "$why" "$HUMAN_REF")"
      route_human blocked-human-wait
      return
    fi
  fi
  dead_end "seat reported BLOCKED — $why"; verdict=blocked
}

run_driver_leg() {
  taskpath="$RUNNING/$task"
  # ESCALATION (step_tries): one leg on the escalate seat for one stuck step.
  # Checked before the move, so a missing seat leaves the task in queue/.
  local dseat="$DRIVER_SEAT" esc_claim="" why
  if [ -s "$(state_file escalate-next)" ]; then
    esc_claim=$(cat "$(state_file escalate-next)")
    dseat="${ESCALATE_SEAT:-$DRIVER_SEAT}"
    why=$(seat_check "$dseat") || die "escalation: $why — $task stays in queue/"
  fi
  move "$QUEUE/$task" "$taskpath"
  task_io
  # Captured while the file is still in running/: get_legs reads $taskpath,
  # and by receipt time the task has been moved out from under it.
  legspent=$(get_legs)
  ts=$(date -Is)
  # $$ in the name: two legs of the same task inside one second (bounce +
  # immediate re-run) must not share a log file — the demo proved they can.
  log="$LOGS/${task%.md}.$(date +%Y%m%d-%H%M%S).$$.log"

  # Baseline BEFORE the leg touches anything: this is the "before" half of
  # the progress rule, and it is captured here because the driver leg is where
  # a round trip starts.
  capture_baseline
  snapshot_prebump
  bump_legs

  # LEG TYPE is decided by the file, not by anyone's claim: no checklist means
  # nobody has said how this would be proven, so the seat that runs is the
  # spec seat. The spec prompt carries the TASK FILE path (the driver prompt
  # never does — the driver is given content, not location) because the spec
  # seat's one permitted write is an append to that file.
  export CONVEYOR_LEG_SEAT="$dseat"   # Actor for any receipt row this leg writes
  spec_leg=0; seat_name=driver; tmo="$TASK_TIMEOUT"
  [ -n "$esc_claim" ] && seat_name=escalated
  # SPEC_ALWAYS=1 (the incoming-requests belt) keys on "## Spec" instead of
  # "## Checklist": a checklist can arrive in the submitted text, a "## Spec"
  # heading can only have been written by route_spec on this belt.
  if [ "$SPEC_ALWAYS" = "1" ]; then
    spec_needed=1; grep -q '^## Spec' "$taskpath" && spec_needed=0
  else
    spec_needed=0; grep -q '^## Checklist' "$taskpath" || spec_needed=1
  fi
  if [ "$spec_needed" -eq 1 ]; then
    spec_leg=1; seat_name=spec; tmo="$SPEC_TIMEOUT"
    prompt="$(cat "$SPREAMBLE"; printf 'TASK FILE: %s\n\nTHE TASK:\n\n' "$taskpath"; cat "$taskpath"; io_note)"
  else
    prompt="$(cat "$PREAMBLE" "$taskpath"; io_note)"
    [ -n "$esc_claim" ] && prompt="$prompt$(printf '\n\nESCALATED STEP: "%s" has failed its check %s times on the %s seat. You are brought in for this one leg: make that step pass first, and leave the steps that already pass alone.\n' "$esc_claim" "$STEP_TRIES" "$DRIVER_SEAT")"
  fi

  # cwd must be /home/operator so the session loads ~/CLAUDE.md (cwd+ancestors)
  cd "$HOME" || die "cd \$HOME failed"
  : > "$log" || die "log truncate failed for $task"
  # The seat is named in the log for the same reason the verify leg names its
  # own: a codex leg and a claude leg on the same task are only comparable if
  # the file says which ran.
  printf -- '--- %s leg (%s seat) ---\n' "$seat_name" "$dseat" >> "$log" \
    || die "log append failed for $task"
  run_seat "$dseat" "$tmo" "$prompt" "$log"
  rc=$SEAT_RC
  # The escalation is spent once the seat answered (a crash keeps it for the retry).
  [ $rc -eq 0 ] && rm -f "$(state_file escalate-next)"
  # Before ANY routing reads a tick. On a crash the prebump restore below
  # supersedes this, which is the correct direction: the task goes back
  # byte-for-byte as it was.
  erase_hand_ticks

  # The verdict is the FINAL non-blank line, matched exactly — not a grep
  # over the whole transcript (08-30 audit: a leg that merely QUOTED
  # "RESULT: done" mid-stream used to file as done).
  mint_failed=0; surface_failed=""; seat_crash_fresh=0
  [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"   # a working seat closes the incident and clears the backoff
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    # timeout(1): 124 on expiry, 137 when it had to KILL. The seat ran its
    # whole clock and never answered — a cut-off, leg charged (bump_legs).
    dead_end "seat cut off by the ${tmo}s timeout (rc $rc) — last line: $(printf '%s' "${SEAT_FINAL:-(seat wrote nothing)}" | cut -c1-120)"
    verdict=timeout
  elif [ $rc -ne 0 ]; then
    seat_crash "$rc" "$QUEUE" "$dseat"
  elif [ "$spec_leg" -eq 1 ]; then
    # A spec leg has ONE valid ending and the file must back it. Every other
    # ending bounces with the why written in — never done/, never a silent
    # failed/ — and the leg ceiling is the backstop for a task the spec seat
    # cannot make sense of, which then surfaces through the dead-end path.
    final="$SEAT_FINAL"
    case "$final" in
      "RESULT: spec"*)
        if why=$(spec_shape_ok); then
          route_spec
        else
          spec_bounce spec-malformed "$(printf 'Spec leg ended RESULT: spec at %s (log: %s) but the file is not in spec shape: %s. Back to queue/ for another spec leg.' \
            "$(date -Is)" "$log" "$why")"
        fi ;;
      "RESULT: done"*)
        spec_bounce spec-ignored "$(printf 'Spec leg ended RESULT: done at %s (log: %s) — it BUILT instead of specifying. Nothing files as done without a checklist %s confirmed. Back to queue/ for a spec leg; whatever was built is in that log.' \
          "$(date -Is)" "$log" "$HUMAN_REF")" ;;
      *)
        spec_bounce spec-no-result "$(printf 'Spec leg ended "%s" at %s (log: %s) — not RESULT: spec. Ambiguity is the input to this seat, not a reason to stop; back to queue/.' \
          "${final:-(no final line)}" "$(date -Is)" "$log")" ;;
    esac
  else
    final="$SEAT_FINAL"
    # BLOCKED and no-RESULT both go through dead_end (header: EVERY ANSWER IS
    # HEARD). The reason names which, and quotes the seat's last line; verdict
    # is set AFTER the call so receipts.jsonl still distinguishes them from a
    # stop-rule dead end. The :dead-end intent suffix is kept on purpose — it
    # is what conveyor-tap recognises (and skips; that door is not built here).
    # (2026-10-26) BLOCKED goes through route_blocked: a block whose only open
    # steps are HUMAN parks in human/ instead; every other block is still this
    # dead end.
    case "$final" in
      "RESULT: done"*)    route_done ;;
      "RESULT: blocked"*) route_blocked "$final" ;;
      *)
        dead_end "seat ended with no RESULT line (crash or cut-off) — last line: $(printf '%s' "${final:-(seat wrote nothing)}" | cut -c1-120)"; verdict=no-result-line ;;
    esac
  fi

  receipt "$ts" "$task" "$verdict" "$rc" "\"$log\"" "$legspent" "$seat_name"
  close_out
  # Receipt written first so the failure is on the record, THEN the belt
  # reports itself broken: a task is waiting in human/ with NO intent in
  # the operator's queue, which nothing retries.
  [ -n "$surface_failed" ] \
    && die "dead end for $task reached failed/ but these channels did NOT fire:$surface_failed"
  [ "$mint_failed" -eq 1 ] \
    && die "intent mint failed for $task (in human/, unsurfaced)"
  seat_crash_exit
}

# Routing after a verifier's VERDICT: pass — trust the checker over the
# second seat too: a pass over an unticked non-HUMAN step is overridden.
verify_pass_route() {
  if ! grep -q '^## Checklist' "$taskpath"; then
    # A task cannot reach verify/ without a checklist through the belt; one
    # here was hand-moved. It does not file as done on a verifier's word any
    # more than on a driver's — it goes to queue/ for the spec leg it skipped.
    spec_bounce verify-no-checklist "$(printf 'Verifier said VERDICT: pass at %s (log: %s) on a task with no checklist. Nothing files as done on a claim; back to queue/ for a spec leg.' \
      "$(date -Is)" "$log")"
    return
  fi
  run_check "post-verify gate"
  if [ $crc -eq 0 ]; then
    if printf '%s\n' "$checkout" | grep -q '^\[ \] HUMAN '; then
      # A verifier-appended HUMAN step: everything else proved, so park it
      # for the operator rather than bouncing a leg that can never tick it.
      route_human verify-human-wait
    elif [ "$REVIEW_GATE" = 1 ]; then
      # REVIEW GATE: proven by the checks and passed by the verifier is still a
      # PROPOSED result. It waits in human/ until a person accepts it into done/.
      plan_note "Result proposed (waiting for your yes)" "$(printf 'Every check passed after the work leg and the verifier (%s) passed it at %s (log: %s). This is a PROPOSAL until a person accepts it: runner/ragnarok/belt accept moves it to done/, belt reject moves it to failed/.' \
        "$VERIFIER_SEAT" "$(date -Is)" "$log")"
      move "$taskpath" "$HUMAN/$task"; verdict=verify-pass-proposed
      rm -f "$(state_file steptries)" "$(state_file escalated)" "$(state_file escalate-next)"
      mint_intent "$task:accept" "$(printf 'RESULT: %s — waiting for your yes' "$(sed -n '1s/^#[[:space:]]*//p' "$HUMAN/$task")" | cut -c1-100)" \
        "$(printf 'Checks and verifier passed. Read the result, then accept or reject.\n\nTask file:\n%s' "$HUMAN/$task")" \
        || { verdict=verify-pass-proposed-intent-failed; mint_failed=1; }
    else
      move "$taskpath" "$DONE/$task"; verdict=verify-pass; close_pending=done
      rm -f "$(state_file steptries)" "$(state_file escalated)" "$(state_file escalate-next)"
    fi
  elif [ $crc -eq 1 ]; then
    append_leg verifier "$(printf 'Verifier said VERDICT: pass but the runner'\''s post-check refutes the checklist — pass OVERRIDDEN (log: %s):\n\n```\n%s\n```' \
      "$log" "$checkout")"
    # A verify leg ran, so this closes a full round trip: the stop rule applies.
    verdict=verify-pass-check-fail; route_bounce 1
  else
    move "$taskpath" "$FAILED/$task"; verdict=verify-check-error
  fi
}

run_verify_leg() {
  taskpath="$RUNNING/$task"
  move "$VERIFY/$task" "$taskpath"
  task_io
  legspent=$(get_legs)
  ts=$(date -Is)
  log="$LOGS/${task%.md}.$(date +%Y%m%d-%H%M%S).$$.log"

  # Staging pre-check: a checklist that regressed since the driver leg
  # bounces the task WITHOUT spending a verify leg, and the output rides
  # into the prompt as evidence for the seat that does run.
  if grep -q '^## Checklist' "$taskpath"; then
    run_check "verify staging pre-check"
    if [ $crc -eq 1 ]; then
      # A confirmed spec that has not had a driver leg yet is not a REGRESSION —
      # nothing was ever built. Say that, rather than writing "refuted" into the
      # record of a task nobody has touched. (conveyor-tap sends a spec straight
      # to queue/, so this is the hand-moved case; the wording still matters.)
      if grep -q '^## Spec' "$taskpath" && ! grep -qE '^## Leg [0-9]+ — driver' "$taskpath"; then
        append_leg verifier "$(printf 'Spec is confirmed and no driver leg has run yet — nothing to verify. Back to queue/ for the first build leg; no model invoked (log: %s):\n\n```\n%s\n```' \
          "$log" "$checkout")"
      else
        append_leg verifier "$(printf 'Runner staging check refuted the checklist BEFORE a verify leg was spent — no model invoked (log: %s):\n\n```\n%s\n```' \
          "$log" "$checkout")"
      fi
      # No seat ran, so no round trip completed — ceiling only, and the
      # receipt's seat is "runner" because no model was invoked.
      verdict=verify-precheck-fail; mint_failed=0; surface_failed=""
      route_bounce 0
      receipt "$ts" "$task" "$verdict" 0 "\"$log\"" "$legspent" runner
      close_out
      [ -n "$surface_failed" ] \
        && die "dead end for $task reached failed/ but these channels did NOT fire:$surface_failed"
      [ "$mint_failed" -eq 1 ] \
        && die "intent mint failed for $task (dead end, unsurfaced)"
      return 0
    elif [ $crc -ge 2 ]; then
      move "$taskpath" "$FAILED/$task"
      receipt "$ts" "$task" verify-check-error 0 "\"$log\"" "$legspent" runner
      close_out
      return 0
    fi
  else
    checkout="(no ## Checklist section — nothing for conveyor-check to run)"
  fi

  vprompt="$(
    cat "$VPREAMBLE"
    printf '\nTASK FILE: %s\nCHECKER: %s\nBELT ROOT: %s\n\nTASK FILE CONTENT:\n\n' \
      "$taskpath" "$CHECK" "$ROOT"
    cat "$taskpath"
    io_note
    printf '\n--- conveyor-check at staging (runner-run) ---\n%s\n' "$checkout"
  )"

  snapshot_prebump
  bump_legs
  cd "$HOME" || die "cd \$HOME failed"
  export CONVEYOR_LEG_SEAT="$VERIFIER_SEAT" # Actor for any receipt row this leg writes
  printf -- '\n--- verifier leg (%s seat) ---\n' "$VERIFIER_SEAT" >> "$log" \
    || die "log append failed for $task"
  run_seat "$VERIFIER_SEAT" "$VERIFY_TIMEOUT" "$vprompt" "$log"
  rc=$SEAT_RC
  # The verifier is told never to tick; this is what makes that structural.
  erase_hand_ticks

  mint_failed=0; surface_failed=""; seat_crash_fresh=0
  [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    dead_end "verifier cut off by the ${VERIFY_TIMEOUT}s timeout (rc $rc) — last line: $(printf '%s' "${SEAT_FINAL:-(seat wrote nothing)}" | cut -c1-120)"
    verdict=verify-timeout
  elif [ $rc -ne 0 ]; then
    # Same class as the driver's: the seat, not the task, failed. Back to
    # verify/ — it was waiting for a verifier, and queue/ would spend a driver
    # leg re-proving what the staging check already saw.
    seat_crash "$rc" "$VERIFY" "$VERIFIER_SEAT"
  else
    final="$SEAT_FINAL"
    case "$final" in
      "VERDICT: pass"*) verify_pass_route ;;
      "VERDICT: fail"*)
        # Append the seat's full picture — CONFIRMED lines too, they are
        # what the next driver leg starts from.
        verdlines=$(grep -E '^(CONFIRMED|REFUTED): ' "$log" || true)
        append_leg verifier "$(printf 'Verifier leg verdicts (log: %s):\n\n%s\n\n%s' \
          "$log" "$verdlines" "$final")"
        # Tally BEFORE the stop rule reads it — this leg's refutations count.
        record_refuted "$log"
        verdict=verify-fail; route_bounce 1 ;;
      *)
        # A verifier with no verdict is the same silence as a driver with no
        # RESULT — surfaced the same way (header: EVERY ANSWER IS HEARD).
        dead_end "verifier ended with no VERDICT line (crash or cut-off) — last line: $(printf '%s' "${final:-(seat wrote nothing)}" | cut -c1-120)"; verdict=verify-no-verdict ;;
    esac
  fi

  receipt "$ts" "$task" "$verdict" "$rc" "\"$log\"" "$legspent" verifier
  close_out
  [ -n "$surface_failed" ] \
    && die "dead end for $task reached failed/ but these channels did NOT fire:$surface_failed"
  [ "$mint_failed" -eq 1 ] \
    && die "intent mint failed for $task (in human/, unsurfaced)"
  seat_crash_exit
}

# ---- Plan leg: planning first (2026-10-26, SPEC-planning.md) -----------------
# Opt-in: only a task added with `conveyor add --plan` lands in plan/. One
# invocation = one ROUND: the planner seat writes a checklist in its reply, the
# belt rejects it by itself if any step lacks a real check, and otherwise the
# critic seat -- a different maker by default -- lists problems or approves.
# Approved: the plan becomes the task's live checklist and the task goes to
# queue/, where the existing driver/verify legs work it unchanged. Not approved
# after PLAN_ROUNDS rounds: human/, with both sides' notes. No leg is charged
# for a plan round (the leg ceiling is about building); the round count is the
# plan stage's own limit.
is_planned() { grep -qE '^## Plan (round [0-9]+|approved)' "$taskpath"; }

plan_note() { # heading body
  { printf '\n## %s\n\n' "$1"; printf '%s\n' "$2"; } >> "$taskpath" \
    || die "task-file append failed for $task"
}

# Rounds in the CURRENT planning cycle: a task the operator sends back to plan/
# after a "## Plan needs you" starts again at round 1.
plan_round() {
  awk '/^## Plan needs you/{n=0} /^## Plan round [0-9]+ — planner/{n++} END{print n+0}' "$taskpath"
}

# At the start of a cycle, no checklist may be live yet: the PLAN is what the
# build is held to, not whatever was typed into the request (or left over from
# an earlier cycle). Step lines and checklist headings are quoted in place with
# "> ", which conveyor-check's STEP_RE does not match; the words stay readable.
plan_quarantine() {
  grep -qE '^([[:space:]]*- \[|## Checklist)' "$taskpath" || return 0
  local tmp="$taskpath.q.$$"
  sed -E 's/^([[:space:]]*- \[|## Checklist)/> \1/' "$taskpath" > "$tmp" \
    && cat "$tmp" > "$taskpath" || die "plan quarantine failed for $task"
  rm -f "$tmp"
}

# The plan is the step lines after the LAST "## Checklist" heading in the
# planner's reply ($log holds the model's text and nothing else -- run_seat).
plan_extract() { # out-file
  awk '/^## Checklist[[:space:]]*$/{buf=""; f=1; next}
       f && /^[[:space:]]*- \[/{buf=buf $0 "\n"}
       END{printf "%s", buf}' "$log" > "$1" || die "plan extract failed for $task"
}

# Is every step a real, checkable step? Prints the problems, one per line, and
# returns 1 if there are any. STEP_RE is conveyor-check's, copied: a line it
# would not parse is a line the belt would never check.
plan_shape_ok() { # steps-file
  local out
  [ -s "$1" ] || { echo "no checklist steps (want '- [ ] <step> :: verify: <command>' lines under a '## Checklist' heading)"; return 1; }
  out=$(python3 - "$1" <<'PY'
import re, sys
STEP = re.compile(r"^(\s*- \[)( |x)(\] )(.*?) :: verify: (.*)$")
seen, out = set(), []
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    m = STEP.match(line)
    if not m:
        out.append("has no check: " + line.strip()); continue
    if m.group(2) == "x":
        out.append("arrived already ticked: " + line.strip()); continue
    rest = m.group(5); i = rest.rfind(" :: expect: ")
    cmd = (rest if i == -1 else rest[:i]).strip()
    if cmd == "HUMAN":
        out.append("is a HUMAN step (every planned step is checked by a command): " + line.strip())
    elif cmd in ("", "true", ":", "exit 0", "/bin/true", "/usr/bin/true"):
        out.append("has a check that proves nothing: " + line.strip())
    if m.group(4) in seen:
        out.append("repeats an earlier step's wording (each step needs its own): " + line.strip())
    seen.add(m.group(4))
print("\n".join(out))
PY
) || { echo "plan could not be read"; return 1; }
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"; return 1
}

# After a round that did not approve: another round, or the operator.
plan_next() { # round valid(0|1)
  if [ "$1" -ge "$PLAN_ROUNDS" ]; then
    plan_deadlock "$1" "$2"
  else
    move "$taskpath" "$PLAN/$task"
  fi
}

plan_deadlock() { # round valid(0|1)
  local title body steps
  steps="$(state_file plansteps)"
  if [ "$2" -eq 1 ]; then
    plan_note "Plan needs you" "$(printf 'The planner (%s) and the critic (%s) did not agree in %s rounds. Both sides'"'"' notes are above.\n\nApprove = the belt builds the last plan anyway (the box below). Or edit the request at the top and move this file back to plan/ to plan again from round 1.\n\n## Checklist\n- [ ] you accept this plan even though the critic did not approve it :: verify: HUMAN\n%s' \
      "$PLANNER_SEAT" "$CRITIC_SEAT" "$1" "$(cat "$steps")")"
  else
    plan_note "Plan needs you" "$(printf 'No usable plan came out of %s rounds (planner %s, critic %s). Every round'"'"'s notes are above. Nothing was built.\n\nEdit the request at the top to say more, then move this file back to plan/ to plan again from round 1.' \
      "$1" "$PLANNER_SEAT" "$CRITIC_SEAT")"
  fi
  move "$taskpath" "$HUMAN/$task"
  verdict=plan-deadlock
  title=$(sed -n '1s/^#[[:space:]]*//p' "$HUMAN/$task")
  body="${title:-$task}

THE PLANNER AND THE CRITIC DID NOT AGREE after $1 round(s). Nothing has been built.
$( [ "$2" -eq 1 ] && echo "Approve = build the last plan anyway. Or edit the request and move it back to plan/." \
                  || echo "No valid plan. Edit the request and move it back to plan/.")

Task file, with both sides' notes:
$HUMAN/$task"
  mint_intent "$task:plan" "$(printf 'PLAN: %s — planner and critic did not agree' "${title:-$task}" | cut -c1-100)" "$body" \
    || { verdict=plan-deadlock-intent-failed; mint_failed=1; }
}

# REVIEW GATE: a plan the critic passed waits for a person. $1 round, $2 the
# checklist lines (already "- [ ] claim :: verify: ..."). Same shape as
# plan_deadlock's "accept anyway" box, so a person's Approve works the same way.
plan_propose() { # round steps-text
  local title body
  plan_note "Plan proposed — round $1 (waiting for your yes)" "$(printf 'Planner: %s. Critic: %s (it passed). This is a PROPOSAL: nothing is built until a person approves it (runner/ragnarok/belt approve).\n\n## Checklist\n- [ ] you approve this plan before any work runs :: verify: HUMAN\n%s' \
    "$PLANNER_SEAT" "$CRITIC_SEAT" "$2")"
  move "$taskpath" "$HUMAN/$task"
  verdict=plan-proposed
  title=$(sed -n '1s/^#[[:space:]]*//p' "$HUMAN/$task")
  body="${title:-$task}

THE PLANNER WROTE A PLAN AND THE CRITIC PASSED IT. Nothing has been built.
Approve = tick the box and put it on the belt. Or edit the request and move it back to plan/.

Task file:
$HUMAN/$task"
  mint_intent "$task:plan" "$(printf 'PLAN: %s — waiting for your yes' "${title:-$task}" | cut -c1-100)" "$body" \
    || { verdict=plan-proposed-intent-failed; mint_failed=1; }
}

run_plan_leg() {
  if is_json_plan "$PLAN/$task"; then run_json_plan_leg; return; fi
  local why s round steps quoted clog problems valid=0 nl=$'\n'
  # Seats and preambles checked BEFORE the task moves: a missing critic leaves
  # it in plan/, where it waits, and the belt says why on every run.
  for s in "$PLANNER_SEAT" "$CRITIC_SEAT"; do
    why=$(seat_check "$s") || die "plan stage: $why — $task stays in plan/"
  done
  [ -r "$PPREAMBLE" ] || die "planner-preamble.md not found at $PPREAMBLE"
  [ -r "$CPREAMBLE" ] || die "critic-preamble.md not found at $CPREAMBLE"
  taskpath="$RUNNING/$task"
  move "$PLAN/$task" "$taskpath"
  task_io
  legspent=$(get_legs)
  ts=$(date -Is)
  log="$LOGS/${task%.md}.plan.$(date +%Y%m%d-%H%M%S).$$.log"
  mint_failed=0; surface_failed=""; seat_crash_fresh=0; seat_name=planner
  round=$(( $(plan_round) + 1 ))
  [ "$round" -eq 1 ] && plan_quarantine
  snapshot_prebump
  cat "$(state_file prebump)" > "$(state_file planstart)" || die "plan snapshot failed for $task"
  cd "$HOME" || die "cd \$HOME failed"
  : > "$log" || die "log truncate failed for $task"
  printf -- '--- planner leg (%s seat) ---\nround %s of %s\n' "$PLANNER_SEAT" "$round" "$PLAN_ROUNDS" >> "$log" \
    || die "log append failed for $task"
  export CONVEYOR_LEG_SEAT="$PLANNER_SEAT"
  prompt="$(cat "$PPREAMBLE"; printf '\nROUND: %s of %s\n\nTHE TASK (with every earlier round'"'"'s plan and critique, if any):\n\n' "$round" "$PLAN_ROUNDS"; cat "$taskpath"; io_note)"
  run_seat "$PLANNER_SEAT" "$PLAN_TIMEOUT" "$prompt" "$log"
  rc=$SEAT_RC
  # The planner answers in its REPLY; anything it did to the task file is undone.
  cat "$(state_file prebump)" > "$taskpath" || die "task restore failed for $task"
  [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    dead_end "planner cut off by the ${PLAN_TIMEOUT}s timeout (rc $rc)"; verdict=plan-timeout
  elif [ $rc -ne 0 ]; then
    seat_crash "$rc" "$PLAN" "$PLANNER_SEAT"
  else
    steps="$(state_file plansteps)"
    plan_extract "$steps"
    quoted=$( { printf '## Checklist\n'; cat "$steps"; } | sed 's/^/> /')
    case "$SEAT_FINAL" in
      "RESULT: plan"*) why=$(plan_shape_ok "$steps") && valid=1 ;;
      *) why="the reply did not end with RESULT: plan (last line: $(printf '%s' "${SEAT_FINAL:-(nothing)}" | cut -c1-120))" ;;
    esac
    if [ "$valid" -eq 0 ]; then
      plan_note "Plan round $round — planner ($PLANNER_SEAT)" "$(printf 'REJECTED by the belt before the critic saw it:\n\n%s\n\nThe plan as written (quoted, not live):\n\n%s\n\nPlanner transcript: %s' "$why" "$quoted" "$log")"
      verdict=plan-rejected
      plan_next "$round" 0
    else
      plan_note "Plan round $round — planner ($PLANNER_SEAT)" "$(printf 'The plan (quoted; it becomes live only when approved):\n\n%s\n\nPlanner transcript: %s' "$quoted" "$log")"
      # ---- the critic, same invocation: a plan is one round, planner+critic ----
      snapshot_prebump
      seat_name=critic
      export CONVEYOR_LEG_SEAT="$CRITIC_SEAT"
      clog="${log%.log}.critic.log"; log="$clog"
      printf -- '--- critic leg (%s seat) ---\nround %s of %s\n' "$CRITIC_SEAT" "$round" "$PLAN_ROUNDS" > "$log" \
        || die "log append failed for $task"
      prompt="$(cat "$CPREAMBLE"; printf '\nROUND: %s of %s\n\nTHE TASK, WITH THE PLAN TO REVIEW (the last "Plan round" block):\n\n' "$round" "$PLAN_ROUNDS"; cat "$taskpath"; io_note)"
      run_seat "$CRITIC_SEAT" "$PLAN_TIMEOUT" "$prompt" "$log"
      rc=$SEAT_RC
      cat "$(state_file prebump)" > "$taskpath" || die "task restore failed for $task"
      [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"
      if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
        dead_end "critic cut off by the ${PLAN_TIMEOUT}s timeout (rc $rc)"; verdict=plan-timeout
      elif [ $rc -ne 0 ]; then
        # Refund the WHOLE round: the planner's note goes too, so the next
        # run is the same round again rather than a plan nobody reviewed.
        cat "$(state_file planstart)" > "$(state_file prebump)" || die "plan restore failed for $task"
        seat_crash "$rc" "$PLAN" "$CRITIC_SEAT"
      else
        problems=$(grep -E '^PROBLEM: ' "$log" || true)
        case "$SEAT_FINAL" in
          "VERDICT: approved"*)
            plan_note "Plan round $round — critic ($CRITIC_SEAT)" "$(printf 'APPROVED.%s\n\nCritic transcript: %s' "${problems:+${nl}${nl}Notes it gave anyway:${nl}$problems}" "$log")"
            if [ "$REVIEW_GATE" = 1 ]; then
              plan_propose "$round" "$(cat "$steps")"
            else
              plan_note "Plan approved — round $round" "$(printf 'Planner: %s. Critic: %s. These steps are now the live checklist; the belt runs every check after each work leg, and the final verifier still has the last word.\n\n## Checklist\n%s' \
                "$PLANNER_SEAT" "$CRITIC_SEAT" "$(cat "$steps")")"
              move "$taskpath" "$QUEUE/$task"; verdict=plan-approved
            fi ;;
          *)
            [ "$SEAT_FINAL" = "VERDICT: problems" ] || problems="$problems${problems:+$nl}(the critic gave no VERDICT line — last line: $(printf '%s' "${SEAT_FINAL:-(nothing)}" | cut -c1-120); counted as not approved)"
            plan_note "Plan round $round — critic ($CRITIC_SEAT)" "$(printf 'NOT APPROVED:\n\n%s\n\nCritic transcript: %s' "${problems:-(no PROBLEM lines given)}" "$log")"
            verdict=plan-revise
            plan_next "$round" 1 ;;
        esac
      fi
    fi
  fi
  case "$verdict" in plan-approved|plan-proposed*|plan-deadlock*|plan-timeout) rm -f "$(state_file planstart)" "$(state_file plansteps)" ;; esac
  receipt "$ts" "$task" "$verdict" "$rc" "\"$log\"" "$legspent" "$seat_name"
  close_out
  [ -n "$surface_failed" ] \
    && die "dead end for $task reached failed/ but these channels did NOT fire:$surface_failed"
  [ "$mint_failed" -eq 1 ] \
    && die "intent mint failed for $task (in human/, unsurfaced)"
  seat_crash_exit
}

# ---- JSON tasks (branch json-tasks) ----------------------------------------------
is_json_plan() { grep -qE '^plan-format:[[:space:]]*json[[:space:]]*$' "$1"; }

# run_seat, plus: a claude/grok seat that exits nonzero while asked for
# --json-schema is tried once more without it (an older CLI, or a schema it
# will not take), so the flag can never be the reason a plan stalls.
run_json_seat() { # seat timeout prompt log
  run_seat "$1" "$2" "$3" "$4"
  if [ "$SEAT_RC" -ne 0 ] && [ "$SEAT_RC" -ne 124 ] && [ "$SEAT_RC" -ne 137 ] \
     && [ -n "${SEAT_JSON_SCHEMA:-}" ] && [ "$JSON_NATIVE" = 1 ] && { [ "$1" = claude ] || [ "$1" = grok ]; }; then
    printf -- '\n--- the %s seat exited %s with --json-schema; once more without it (prompt + extract) ---\n' "$1" "$SEAT_RC" >> "$4"
    SEAT_JSON_SCHEMA="" run_seat "$1" "$2" "$3" "$4"
  fi
}

# One invocation = one ROUND, as in run_plan_leg: planner (with up to
# JSON_RETRIES re-asks when the validator rejects its JSON), then the critic.
run_json_plan_leg() {
  local why s round try tries errs out tjson vjson base quoted body issues valid=0 native nl=$'\n'
  for s in "$PLANNER_SEAT" "$CRITIC_SEAT"; do
    why=$(seat_check "$s") || die "plan stage: $why — $task stays in plan/"
  done
  [ -r "$JPPREAMBLE" ] || die "planner-json-preamble.md not found at $JPPREAMBLE"
  [ -r "$JCPREAMBLE" ] || die "critic-json-preamble.md not found at $JCPREAMBLE"
  [ -x "$TASKJSON" ] || die "conveyor-taskjson not found at $TASKJSON"
  taskpath="$RUNNING/$task"
  move "$PLAN/$task" "$taskpath"
  task_io
  legspent=$(get_legs)
  ts=$(date -Is)
  base="$LOGS/${task%.md}.plan.$(date +%Y%m%d-%H%M%S).$$"
  log="$base.log"
  mint_failed=0; surface_failed=""; seat_crash_fresh=0; seat_name=planner; verdict=""
  round=$(( $(plan_round) + 1 ))
  [ "$round" -eq 1 ] && plan_quarantine
  snapshot_prebump
  cat "$(state_file prebump)" > "$(state_file planstart)" || die "plan snapshot failed for $task"
  cd "$HOME" || die "cd \$HOME failed"
  tjson="$(state_file task.json)"; vjson="$(state_file verdict.json)"
  tries=$((JSON_RETRIES + 1)); try=0; errs=""; native="$JSON_NATIVE"
  export CONVEYOR_LEG_SEAT="$PLANNER_SEAT"
  while [ "$try" -lt "$tries" ]; do
    try=$((try + 1))
    log="$base.try$try.log"
    printf -- '--- planner leg, JSON (%s seat) ---\nround %s of %s, attempt %s of %s\n' "$PLANNER_SEAT" "$round" "$PLAN_ROUNDS" "$try" "$tries" > "$log" \
      || die "log append failed for $task"
    prompt="$(cat "$JPPREAMBLE"
      printf '\nROUND: %s of %s (attempt %s of %s)\n' "$round" "$PLAN_ROUNDS" "$try" "$tries"
      [ -n "$errs" ] && printf '\nYOUR LAST ANSWER WAS REJECTED BY THE VALIDATOR. Fix every one of these and answer again with the whole JSON object:\n%s\n' "$errs"
      printf '\nTHE TASK (with every earlier round'"'"'s plan and critique, if any):\n\n'; cat "$taskpath"; io_note
      printf '\nTHE TASK SCHEMA (your answer must match it):\n\n'; cat "$SELF_DIR/task-schema/task.schema.json")"
    SEAT_ROLE=planner SEAT_JSON_SCHEMA="$( [ "$native" = 1 ] && python3 "$TASKJSON" schema task)" \
      SEAT_JSON_SCHEMA_FILE="$SELF_DIR/task-schema/task.schema.json" \
      run_json_seat "$PLANNER_SEAT" "$PLAN_TIMEOUT" "$prompt" "$log"
    rc=$SEAT_RC
    cat "$(state_file prebump)" > "$taskpath" || die "task restore failed for $task"
    [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"
    if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
      dead_end "planner cut off by the ${PLAN_TIMEOUT}s timeout (rc $rc)"; verdict=plan-timeout; break
    elif [ $rc -ne 0 ]; then
      seat_crash "$rc" "$PLAN" "$PLANNER_SEAT"; break
    fi
    rm -f "$tjson"
    errs=$(python3 "$TASKJSON" extract-task "${log%.log}.jsonl" "$log" "$tjson" --by "planner:$PLANNER_SEAT" 2>>"$log") \
      && { valid=1; break; }
    printf -- '\n--- the belt rejected this answer ---\n%s\n' "$errs" >> "$log"
    # Asked for structured output and got nothing readable: ask plainly next time.
    case "$errs" in "no task JSON found"*) native=0 ;; esac
  done
  if [ -z "$verdict" ]; then
    if [ -s "$tjson" ]; then quoted=$(sed 's/^/> /' "$tjson"); else quoted="> (no JSON object found in the answer)"; fi
    if [ "$valid" -eq 0 ]; then
      plan_note "Plan round $round — planner ($PLANNER_SEAT)" "$(printf 'REJECTED by the validator after %s attempt(s), before the critic saw it:\n\n%s\n\nThe last answer'"'"'s JSON (quoted, not live):\n\n%s\n\nPlanner transcripts: %s.try*.log' "$try" "$errs" "$quoted" "$base")"
      verdict=plan-rejected
      plan_next "$round" 0
    else
      plan_note "Plan round $round — planner ($PLANNER_SEAT)" "$(printf 'Task JSON, valid on attempt %s (quoted; it goes on the belt as soon as the critic passes it, with no human approval step):\n\n%s\n\nPlanner transcript: %s' "$try" "$quoted" "$log")"
      # ---- the critic, same invocation ----
      snapshot_prebump
      seat_name=critic
      export CONVEYOR_LEG_SEAT="$CRITIC_SEAT"
      try=0; errs=""; valid=0; native="$JSON_NATIVE"
      while [ "$try" -lt "$tries" ]; do
        try=$((try + 1))
        log="$base.critic.try$try.log"
        printf -- '--- critic leg, JSON (%s seat) ---\nround %s of %s, attempt %s of %s\n' "$CRITIC_SEAT" "$round" "$PLAN_ROUNDS" "$try" "$tries" > "$log" \
          || die "log append failed for $task"
        prompt="$(cat "$JCPREAMBLE"
          printf '\nROUND: %s of %s\n' "$round" "$PLAN_ROUNDS"
          [ -n "$errs" ] && printf '\nYOUR LAST ANSWER COULD NOT BE READ AS A VERDICT:\n%s\nAnswer again with one JSON object.\n' "$errs"
          printf '\nTHE REQUEST (with every earlier round, if any):\n\n'; cat "$taskpath"; io_note
          printf '\nTASK JSON TO REVIEW:\n\n'; cat "$tjson"
          printf '\nTHE VERDICT SCHEMA:\n\n'; cat "$SELF_DIR/task-schema/critic-verdict.schema.json")"
        SEAT_ROLE=critic SEAT_JSON_SCHEMA="$( [ "$native" = 1 ] && python3 "$TASKJSON" schema verdict)" \
          SEAT_JSON_SCHEMA_FILE="$SELF_DIR/task-schema/critic-verdict.schema.json" \
          run_json_seat "$CRITIC_SEAT" "$PLAN_TIMEOUT" "$prompt" "$log"
        rc=$SEAT_RC
        cat "$(state_file prebump)" > "$taskpath" || die "task restore failed for $task"
        [ $rc -eq 0 ] && rm -f "$SEAT_CRASH_STATE" "$SEAT_BACKOFF_STATE"
        if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
          dead_end "critic cut off by the ${PLAN_TIMEOUT}s timeout (rc $rc)"; verdict=plan-timeout; break
        elif [ $rc -ne 0 ]; then
          # Refund the WHOLE round, as run_plan_leg does.
          cat "$(state_file planstart)" > "$(state_file prebump)" || die "plan restore failed for $task"
          seat_crash "$rc" "$PLAN" "$CRITIC_SEAT"; break
        fi
        out=$(python3 "$TASKJSON" extract-verdict "${log%.log}.jsonl" "$log" "$vjson" 2>>"$log") && { valid=1; break; }
        errs="$out"
        printf -- '\n--- the belt could not read this verdict ---\n%s\n' "$errs" >> "$log"
        case "$errs" in "no verdict JSON found"*) native=0 ;; esac
      done
      if [ -z "$verdict" ]; then
        # The rendered checklist is what a deadlock's "accept anyway" box builds.
        body=$(python3 "$TASKJSON" render "$tjson" --tool "$TASKJSON" --note "$(printf 'Planner: %s. Critic: %s. Planned as JSON; rendered for the coder below. The belt runs every check after each work leg, and the final verifier still has the last word.' "$PLANNER_SEAT" "$CRITIC_SEAT")" 2>>"$log") \
          || die "render failed for $task (see $log)"
        printf '%s\n' "$body" | awk '/^## Checklist$/{f=1; next} f && /^- \[/' > "$(state_file plansteps)" \
          || die "plan steps write failed for $task"
        if [ "$valid" -eq 1 ] && [ "$(printf '%s' "$out" | head -1)" = pass ]; then
          plan_note "Plan round $round — critic ($CRITIC_SEAT)" "$(printf 'PASSED.\n\nCritic transcript: %s' "$log")"
          if [ "$REVIEW_GATE" = 1 ]; then
            plan_propose "$round" "$(cat "$(state_file plansteps)")"
          else
            plan_note "Plan approved — round $round (JSON task, no human approval)" "$body"
            move "$taskpath" "$QUEUE/$task"; verdict=plan-approved
          fi
        else
          if [ "$valid" -eq 1 ]; then issues=$(printf '%s\n' "$out" | sed 1d)
          else issues="(the critic's answer could not be read as a verdict after $try attempt(s): $errs; counted as not passed)"; fi
          plan_note "Plan round $round — critic ($CRITIC_SEAT)" "$(printf 'NOT PASSED:\n\n%s\n\nCritic transcript: %s' "${issues:-(no issues given)}" "$log")"
          verdict=plan-revise
          plan_next "$round" 1
        fi
      fi
    fi
  fi
  case "$verdict" in plan-approved|plan-proposed*|plan-deadlock*|plan-timeout) rm -f "$(state_file planstart)" "$(state_file plansteps)" ;; esac
  receipt "$ts" "$task" "$verdict" "$rc" "\"$log\"" "$legspent" "$seat_name"
  close_out
  [ -n "$surface_failed" ] \
    && die "dead end for $task reached failed/ but these channels did NOT fire:$surface_failed"
  [ "$mint_failed" -eq 1 ] \
    && die "intent mint failed for $task (in human/, unsurfaced)"
  seat_crash_exit
}

# ---- Per-step tries (planned tasks only) --------------------------------------
# After a work leg on a PLANNED task, every step still failing gets one more
# mark in $(state_file steptries). At STEP_TRIES marks on one step: if an
# escalate seat is set and has not had this step yet, the NEXT leg (one leg)
# goes to it; otherwise the task parks on the operator with a HUMAN box for
# that step. Returns 0 when it routed the task (the caller stops), 1 for the
# usual bounce. Unplanned tasks never come here: their behaviour is unchanged.
step_tries() {
  local f e c n claims
  f=$(state_file steptries); e=$(state_file escalated)
  claims=$("$CHECK" --list-json "$taskpath" 2>/dev/null \
    | jq -r 'select((.ticked|not) and (.human|not)) | .claim' 2>/dev/null)
  [ -n "$claims" ] || return 1
  printf '%s\n' "$claims" >> "$f" || die "step tally write failed for $task"
  while IFS= read -r c; do
    n=$(grep -cxF -- "$c" "$f")
    [ "$n" -ge "$STEP_TRIES" ] || continue
    if [ -n "$ESCALATE_SEAT" ] && ! grep -qxF -- "$c" "$e" 2>/dev/null; then
      printf '%s\n' "$c" > "$(state_file escalate-next)" || die "escalation write failed for $task"
      printf '%s\n' "$c" >> "$e"
      append_leg "step escalated" "$(printf 'Step "%s" has failed its check %s times. The next leg goes to the %s seat for this step only; after that, work goes back to the %s seat.' \
        "$c" "$n" "$ESCALATE_SEAT" "$DRIVER_SEAT")"
      verdict=step-escalated
      return 1
    fi
    step_stuck "$c" "$n"
    return 0
  done <<< "$claims"
  return 1
}

step_stuck() { # claim tries
  local k esc=""
  grep -qxF -- "$1" "$(state_file escalated)" 2>/dev/null && esc=", including one leg on the $ESCALATE_SEAT seat"
  k=$(( $(grep -cE '^## Leg [0-9]+ — step stuck' "$taskpath") + 1 ))
  append_leg "step stuck" "$(printf 'Step "%s" failed its check %s times%s. The belt stopped and is asking you.\n\n- [ ] you have looked at the stuck step "%s" and want the belt to try again (stuck #%s) :: verify: HUMAN\n\nApprove = the belt tries again with a fresh count. To change the step itself, edit it in the checklist first.' \
    "$1" "$2" "$esc" "$1" "$k")"
  rm -f "$(state_file steptries)" "$(state_file escalated)" "$(state_file escalate-next)"
  run_check "stuck step parked"
  route_human step-stuck
}

mkdir -p "$PLAN" "$QUEUE" "$RUNNING" "$DONE" "$FAILED" "$VERIFY" "$HUMAN" "$LOGS"
[ -x "$CHECK" ] || die "conveyor-check not found at $CHECK"
[ -r "$PREAMBLE" ] || die "executor-preamble.md not found at $PREAMBLE"
[ -r "$VPREAMBLE" ] || die "verifier-preamble.md not found at $VPREAMBLE"
[ -r "$SPREAMBLE" ] || die "spec-preamble.md not found at $SPREAMBLE"
# Checked at startup, not at the moment of a dead end: a belt that cannot
# surface a loss must say so on every run, not once, months in, when the first
# dead end happens to be the thing that discovers it.
[ -x "$NOTIFY" ] || die "notify sender not found at $NOTIFY"
[ -x "$YGG" ] || die "receipt writer not found at $YGG"
[ -x "$CLOSE" ] || die "closer not found at $CLOSE"
# Only the seats actually SELECTED need a binary. This was an unconditional
# `[ -x "$CLAUDE" ]` until 2026-09-03, which meant a fully codex-configured
# belt still refused to start the moment the claude binary went away -- the
# exact failure the seat swap exists to prevent, sitting one line above it.
for __seat in "$DRIVER_SEAT" "$VERIFIER_SEAT"; do
  __why=$(seat_check "$__seat") || die "$__why"
done
unset __seat __why

# Crash recovery: a task stranded in running/ means a previous run died hard
# (reboot, kill). Move it to failed/ with a note instead of losing it.
for stranded in "$RUNNING"/*.md; do
  [ -e "$stranded" ] || break
  # Holders are judged by the PIDs fuser PRINTS, not its exit code: macOS
  # fuser exits 0 with nobody holding the file, so a stranded task was never
  # recovered on a Mac (found 2026-10-26 when the app's Stop left one behind).
  if [ -z "$(fuser "$ROOT/.lock" 2>/dev/null | tr -d '[:space:]')" ]; then
    move "$stranded" "$FAILED/$(basename "$stranded")"
    receipt "$(date -Is)" "$(basename "$stranded")" stranded -1 null 0 runner
  fi
done

exec 9>"$ROOT/.lock"
flock -n 9 || exit 0   # another run is live; that is fine, not an error

# A belt with no working seat waits instead of spending. Exit 0: serving a
# backoff is the belt working correctly, not the belt broken.
backoff_holding && exit 0

# One leg per invocation (the serial throttle is the spend cap — Slice 4
# ruling). verify/ first: finishing what is in flight beats starting more.
task=$(ls -1 "$VERIFY" 2>/dev/null | grep '\.md$' | sort | head -1 || true)
if [ -n "${task:-}" ]; then
  run_verify_leg
else
  task=$(ls -1 "$QUEUE" 2>/dev/null | grep '\.md$' | sort | head -1 || true)
  if [ -n "${task:-}" ]; then
    run_driver_leg
  else
    # plan/ last: building what is already planned beats planning more.
    task=$(ls -1 "$PLAN" 2>/dev/null | grep '\.md$' | sort | head -1 || true)
    [ -z "${task:-}" ] && exit 0
    run_plan_leg
  fi
fi
exit 0
