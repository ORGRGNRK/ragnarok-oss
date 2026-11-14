#!/usr/bin/env bash
# Hermetic fixtures for claude-export-unpack.
#
# HERMETIC: it never reads this box's real credentials and never touches
# ~/claude-chats. ragnarok-save is STUBBED through $CLAUDE_EXPORT_SAVE_SCRIPT,
# secrets are planted through $CLAUDE_EXPORT_SECRETS_FILE, and every zip is
# built here in a temp dir.
#
# THE LOAD-BEARING FAMILY IS THE NEGATIVE CONTROLS (cases 8-12): a planted
# credential must appear ZERO times in the output tree, a missing redactor must
# write NOTHING, an empty secret set must write NOTHING, and a redactor that
# does not redact must SKIP the file and exit 1. Mutation-prove them by making
# redact() the identity function — 11 and 12 must fail.
set -uo pipefail
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # Linux or Mac
SCRIPT="${SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/claude-export-unpack}"
T=$(mktemp -d); C=$(mktemp -d); trap 'rm -rf "$T" "$C"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
has(){ if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1 (missing '$2')"; fi; }

SECRET='sk-ant-FAKE-PLANTED-VALUE-0123456789'
printf '%s\n' "$SECRET" > "$T/secrets.txt"

# --- stub ragnarok-save: same API surface the real one exposes -------------
cat > "$T/save-stub" <<'EOF'
def collect_secrets():
    return None, set(), ["stub"]
def redact(text, secrets):
    found = {}
    for v in sorted(secrets, key=len, reverse=True):
        n = text.count(v)
        if n:
            text = text.replace(v, "[REDACTED-CREDENTIAL]")
            found["known-secret"] = found.get("known-secret", 0) + n
    return text, found
EOF
cat > "$T/save-noredact" <<'EOF'
def collect_secrets():
    return None, set(), ["stub"]
def redact(text, secrets):
    return text, {}
EOF
cat > "$T/save-nosecrets" <<'EOF'
def collect_secrets():
    return None, set(), []
def redact(text, secrets):
    return text, {}
EOF

# --- fixture zips ----------------------------------------------------------
python3 - "$T" "$SECRET" <<'EOF'
import json, os, sys, zipfile
T, SECRET = sys.argv[1], sys.argv[2]
def msg(u, sender, text, parent="p0", blocks=None):
    return {"uuid": u, "sender": sender, "text": text, "parent_message_uuid": parent,
            "created_at": "2026-05-01T10:00:00Z", "updated_at": "2026-05-01T10:00:00Z",
            "content": json.dumps(blocks if blocks is not None else [{"type": "text", "text": text}]),
            "attachments": "[]", "files": "[]"}
convs = [
  {"uuid": "aaaaaaaa-1111-2222-3333-444444444444", "name": "Phone grading rig",
   "created_at": "2026-05-01T10:00:00Z", "updated_at": "2026-05-01T11:00:00Z", "account": {},
   "chat_messages": [
      msg("m1", "human", "how do I grade a cracked screen"),
      msg("m2", "assistant", "", parent="m1", blocks=[
          {"type": "thinking", "thinking": "T" * 9000},
          {"type": "text", "text": "Check the corners first."},
          {"type": "tool_use", "name": "airtable_list_records", "input": {"table": "X" * 9000}},
          {"type": "tool_result", "name": "airtable_list_records", "content": "R" * 9000}]),
      # two messages sharing a parent = a branch
      msg("m3", "assistant", "Alternative answer.", parent="m1"),
      msg("m4", "human", "here is my token " + SECRET + " do not leak it", parent="m3")]},
  {"uuid": "dddddddd-1111-2222-3333-444444444444", "name": "Handling credentials securely",
   "created_at": "2026-08-19T14:00:00Z", "updated_at": "2026-08-19T14:30:00Z",
   "chat_messages": [msg("q1", "human", "where do I put the key")]},
  {"uuid": "bbbbbbbb-1111-2222-3333-444444444444", "name": "",
   "created_at": "2026-06-02T09:00:00Z", "updated_at": "2026-06-02T09:30:00Z",
   "chat_messages": [msg("n1", "human", "untitled one"),
                     msg("n2", "assistant", "B" * 4000, parent="n1"),
                     msg("n3", "assistant", "C" * 4000, parent="n2")]}]
with zipfile.ZipFile(os.path.join(T, "conversations-000.zip"), "w") as z:
    z.writestr("conversations.json", json.dumps(convs))
dc = {"uuid": "cccccccc-1111-2222-3333-444444444444", "title": "Design chat",
      "created_at": "2026-07-03T08:00:00Z", "updated_at": "2026-07-03T08:10:00Z",
      "messages": [{"uuid": "d1", "role": "user", "created_at": "2026-07-03T08:00:00Z",
                    "content": {"role": "user", "timestamp": "2026-07-03T08:00:00Z",
                                "content": "make it blue", "attachments": []}}]}
with zipfile.ZipFile(os.path.join(T, "design_chats-000.zip"), "w") as z:
    z.writestr("design_chats/cccccccc.json", json.dumps(dc))
with zipfile.ZipFile(os.path.join(T, "projects-000.zip"), "w") as z:
    z.writestr("projects/0001.json", json.dumps({"name": "a project", "docs": []}))
    z.writestr("projects/0002.json", json.dumps({"name": "another", "docs": []}))
EOF

# stub ragnarok-corpus: only its filename gate matters here
cat > "$T/corpus-stub.py" <<'EOF'
import re
def wanted_file(path, name):
    return not re.search(r"(?i)credential", name) and name.endswith(".md")
EOF
export CLAUDE_EXPORT_CORPUS_SCRIPT="$T/corpus-stub.py"

# A SECOND, CUMULATIVE export: same conversation uuid, later updated_at, extra
# message. This is what actually arrives next time — exports are not deltas.
python3 - "$C" <<'EOF'
import json, os, sys, zipfile
C = sys.argv[1]
def msg(u, sender, text, parent="p0"):
    return {"uuid": u, "sender": sender, "text": text, "parent_message_uuid": parent,
            "created_at": "2026-05-01T10:00:00Z", "updated_at": "2026-05-01T10:00:00Z",
            "content": json.dumps([{"type": "text", "text": text}]),
            "attachments": "[]", "files": "[]"}
old = {"uuid": "eeeeeeee-1111-2222-3333-444444444444", "name": "Cumulative chat",
       "created_at": "2026-05-01T10:00:00Z", "updated_at": "2026-05-01T11:00:00Z",
       "chat_messages": [msg("z1", "human", "FIRST EXPORT ONLY")]}
new = dict(old, updated_at="2026-05-09T11:00:00Z",
           chat_messages=[msg("z1", "human", "FIRST EXPORT ONLY"),
                          msg("z2", "assistant", "SECOND EXPORT ADDED THIS", parent="z1")])
for sub, conv in (("a-older", old), ("b-newer", new)):
    d = os.path.join(C, sub); os.makedirs(d, exist_ok=True)
    with zipfile.ZipFile(os.path.join(d, "conversations-000.zip"), "w") as z:
        z.writestr("conversations.json", json.dumps([conv]))
EOF

run_src(){ # run_src <srcdir> <outdir> <savestub> [args...]
  local src="$1" out="$2" stub="$3"; shift 3
  CLAUDE_EXPORT_SAVE_SCRIPT="$stub" CLAUDE_EXPORT_SECRETS_FILE="$T/secrets.txt" \
    python3 -B "$SCRIPT" "$src" --out "$out" "$@" >"$T/out.txt" 2>"$T/err.txt"
  echo $?
}

run(){ # run <outdir> <savestub> [args...]
  local out="$1" stub="$2"; shift 2
  CLAUDE_EXPORT_SAVE_SCRIPT="$stub" CLAUDE_EXPORT_SECRETS_FILE="$T/secrets.txt" \
    python3 -B "$SCRIPT" "$T" --out "$out" "$@" >"$T/out.txt" 2>"$T/err.txt"
  echo $?
}

echo "claude-export-unpack fixtures"

# 1-7: the happy path
rc=$(run "$T/o1" "$T/save-stub"); chk "1  exit 0 on a clean run" "$rc" "0"
n=$(ls "$T/o1"/*.md 2>/dev/null | wc -l | tr -d ' '); chk "2  four conversations rendered" "$n" "4"
[ -f "$T/o1/2026-05-01-phone-grading-rig-aaaaaaaa.md" ] && ok "3  deterministic name from title+date+uuid8" || no "3  deterministic name from title+date+uuid8"
[ -f "$T/o1/2026-06-02-untitled-bbbbbbbb.md" ] && ok "4  empty title renders as untitled" || no "4  empty title renders as untitled"
[ -f "$T/o1/2026-07-03-design-chat-cccccccc.md" ] && ok "5  design_chats member rendered" || no "5  design_chats member rendered"
has "6  non-chat zip named, not silently dropped" "NOT a chat export, skipped: projects-000.zip" "$T/out.txt"
has "7  skipped members are counted by kind" "projects-000.zip::projects x2" "$T/out.txt"

# 8-12: NEGATIVE CONTROLS
if grep -rqF "$SECRET" "$T/o1"; then no "8  planted credential never reaches the output"
else ok "8  planted credential never reaches the output"; fi
has "9  redaction is reported, not silent" "redacted: {'known-secret'" "$T/out.txt"
rc=$(run "$T/o10" "$T/save-missing-entirely"); chk "10 missing redactor => exit 2" "$rc" "2"
[ -d "$T/o10" ] && no "10b missing redactor writes nothing" || ok "10b missing redactor writes nothing"
rc=$(CLAUDE_EXPORT_SAVE_SCRIPT="$T/save-nosecrets" CLAUDE_EXPORT_SECRETS_FILE="" python3 -B "$SCRIPT" "$T" --out "$T/o11" >"$T/out.txt" 2>"$T/err.txt"; echo $?)
chk "11 empty secret set => exit 2" "$rc" "2"
[ -d "$T/o11" ] && no "11b empty secret set writes nothing" || ok "11b empty secret set writes nothing"
rc=$(run "$T/o12" "$T/save-noredact"); chk "12 a redactor that does not redact => exit 1" "$rc" "1"
if grep -qF "SKIPPED — a live credential survived" "$T/err.txt"; then ok "12b the skipped file is named loudly"
else no "12b the skipped file is named loudly"; fi
if grep -rqF "$SECRET" "$T/o12" 2>/dev/null; then no "12c dirty file is not written"
else ok "12c dirty file is not written"; fi

# 13-16: caps, branches, provenance
has "13 thinking block capped" "chars capped]" "$T/o1/2026-05-01-phone-grading-rig-aaaaaaaa.md"
has "14 branch is disclosed, not flattened silently" "share a parent" "$T/o1/2026-05-01-phone-grading-rig-aaaaaaaa.md"
has "15 source zip and member recorded in the file" "conversations-000.zip::conversations.json" "$T/o1/2026-05-01-phone-grading-rig-aaaaaaaa.md"
has "16 tool_use rendered with its name" "[tool_use: airtable_list_records]" "$T/o1/2026-05-01-phone-grading-rig-aaaaaaaa.md"

# 17-18: --tool-chars 0 omits tools/thinking
rc=$(run "$T/o17" "$T/save-stub" --tool-chars 0 --thinking-chars 0)
if grep -qF "tool_use:" "$T/o17/2026-05-01-phone-grading-rig-aaaaaaaa.md"; then no "17 --tool-chars 0 omits tool blocks"
else ok "17 --tool-chars 0 omits tool blocks"; fi
has "18 omissions are counted in the summary" "tool blocks omitted: 2" "$T/out.txt"

# 19-21: splitting at the corpus tail line
rc=$(run "$T/o19" "$T/save-stub" --max-bytes 3000)
[ -f "$T/o19/2026-06-02-untitled-bbbbbbbb-part02.md" ] && ok "19 oversized conversation splits at a message boundary" \
  || no "19 oversized conversation splits at a message boundary"
has "20 each part says it is a part" "part 2 of" "$T/o19/2026-06-02-untitled-bbbbbbbb-part02.md"
has "21 every part carries the header" "uuid: \`bbbbbbbb-1111-2222-3333-444444444444\`" "$T/o19/2026-06-02-untitled-bbbbbbbb-part02.md"

# 22-24: incremental reruns and --dry-run
export CLAUDE_EXPORT_STATE="$T/state"
rc=$(run "$T/o22" "$T/save-stub"); rc=$(run "$T/o22" "$T/save-stub")
has "22 an unchanged conversation is skipped on rerun" "unchanged, skipped: 4" "$T/out.txt"
rc=$(run "$T/o22" "$T/save-stub" --force)
has "23 --force re-renders" "unchanged, skipped: 0" "$T/out.txt"
unset CLAUDE_EXPORT_STATE
rc=$(run "$T/o24" "$T/save-stub" --dry-run)
if [ -d "$T/o24" ]; then no "24 --dry-run writes nothing"; else ok "24 --dry-run writes nothing"; fi
has "24b --dry-run says so" "DRY RUN — nothing written" "$T/out.txt"

# 25: permissions — chat history is not world-readable
rc=$(run "$T/o25" "$T/save-stub")
chk "25 output files are 0600" "$(mode_of "$T/o25/2026-05-01-phone-grading-rig-aaaaaaaa.md")" "600"
chk "25b output dir is 0700" "$(mode_of "$T/o25")" "700"

# 26-29: THE CORPUS FILENAME GATE — measured on the real export, where two
# credential-titled chats were written and then never walked.
rc=$(run "$T/o26" "$T/save-stub")
[ -f "$T/o26/2026-08-19-handling-securely-dddddddd.md" ] && ok "26 slug word that trips the corpus gate is dropped from the NAME" \
  || no "26 slug word that trips the corpus gate is dropped from the NAME ($(ls "$T/o26" | grep dddddddd))"
has "27 the full title survives inside the document" "# Handling credentials securely" "$T/o26/2026-08-19-handling-securely-dddddddd.md"
has "28 the rename is reported, not silent" "filename word(s) dropped" "$T/out.txt"
# NEGATIVE CONTROL: no gate => the blocked filename comes back, proving the gate does the work
rc=$(CLAUDE_EXPORT_CORPUS_SCRIPT="$T/no-such-corpus.py" run "$T/o29" "$T/save-stub")
[ -f "$T/o29/2026-08-19-handling-credentials-securely-dddddddd.md" ] && ok "29 negative control: no gate => the unwalkable name returns" \
  || no "29 negative control: no gate => the unwalkable name returns"
has "29b a missing corpus gate is announced, not silent" "filenames are NOT checked" "$T/out.txt"

# 30-33: CUMULATIVE EXPORTS. Without dedup the second export he ever drops in
# doubles the corpus with OLDER copies, and the state file then calls both
# unchanged forever. This is the case that must not regress.
rc=$(run_src "$C" "$T/o30" "$T/save-stub")
n=$(ls "$T/o30"/*.md 2>/dev/null | wc -l | tr -d ' '); chk "30 same uuid in two zips => ONE file" "$n" "1"
has "31 the NEWER copy won" "SECOND EXPORT ADDED THIS" "$T/o30/2026-05-01-cumulative-chat-eeeeeeee.md"
has "32 the duplication is reported, not silent" "seen in more than one zip: 1" "$T/out.txt"
if ls "$T/o30" | grep -q -- "-2\.md"; then no "33 no -2.md collision file is produced"
else ok "33 no -2.md collision file is produced"; fi

echo "  ---"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
