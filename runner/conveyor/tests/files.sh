#!/usr/bin/env bash
# files.sh — attachments in, outputs out. NO MODEL IS CALLED.
#
# Proves: `conveyor add --attach` copies any file into attachments/<task-id>/
# (spaces kept, a repeated name gets " (2)"), lists it under "## Attachments"
# by full path, refuses folders and oversize files before writing anything,
# and gives every task an outputs/<task-id>/ folder named on an "outputs:"
# line; conveyor-check hands that folder to verify commands as
# $CONVEYOR_OUTPUTS; and the runner tells a seat where both folders are, so a
# (stub) seat can turn an attachment into an output and the task reaches
# done/ -- while a seat that writes nothing still dead-ends.
#
# The seat is a fake `grok` (same shape as tests/grok-seat.sh), under a
# throwaway HOME. ASSERTION COUNT IS ASSERTED, as in portable.sh.
set -u
PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$PKG/conveyor-run.sh"
CHECK="$PKG/conveyor-check"
PASS=0; FAIL=0
EXPECTED=22
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qE -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 (/$2/ not in $3)"; fi; }

S="$(mktemp -d)"; [ -n "${KEEP:-}" ] && echo "keeping $S" || trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
newroot() { R="$S/$1"; mkdir -p "$R"/{queue,running,verify,human,done,failed,logs}; }
add() { CONVEYOR_ROOT="$R" bash "$PKG/conveyor" add "$@"; }

# Inputs of several kinds, two with the same name, names with spaces.
IN="$S/in"; mkdir -p "$IN/other" "$IN/a folder"
printf 'hello world\n' > "$IN/in put.txt"
printf 'second file, same name\n' > "$IN/other/in put.txt"
printf 'a,b\n1,2\n' > "$IN/data.csv"
printf '%%PDF-1.4 fake\n' > "$IN/report.pdf"
(cd "$IN" && zip -q bundle.zip data.csv 2>/dev/null) || printf 'PK fake' > "$IN/bundle.zip"
head -c 2097152 /dev/zero > "$IN/big.bin"

echo "-- A. conveyor add --attach"
newroot cli
add "Read the inputs" --attach "$IN/in put.txt" -a "$IN/other/in put.txt" --attach "$IN/data.csv" \
    --attach "$IN/report.pdf" --attach "$IN/bundle.zip" \
    -m $'Want: read them\n\n## Checklist\n- [ ] the output folder exists :: verify: test -d "$CONVEYOR_OUTPUTS"' \
    > "$S/add.out" 2>&1; rc=$?
T=$(find "$R/queue" -name '*.md' | head -1); ID=$(basename "${T%.md}")
[ "$rc" -eq 0 ] && [ -n "$T" ] && ok "add with five attachments exits 0 and queues one task" || bad "add failed (rc $rc): $(cat "$S/add.out")"
n=$(grep -cE '^- `/.*`$' "$T" 2>/dev/null); [ "$n" = 5 ] && ok "five attachments listed by full path" || bad "listed $n attachments, want 5"
missing=0; while IFS= read -r p; do [ -f "$p" ] || missing=1; done < <(sed -n 's/^- `\(\/.*\)`$/\1/p' "$T")
[ "$missing" = 0 ] && ok "every listed path exists" || bad "a listed attachment path does not exist"
A="$R/attachments/$ID"
cmp -s "$A/in put.txt" "$IN/in put.txt" && cmp -s "$A/in put (2).txt" "$IN/other/in put.txt" \
  && ok "space kept, second same-name file became 'in put (2).txt', contents identical" || bad "collision/space copy wrong: $(ls "$A")"
cmp -s "$A/report.pdf" "$IN/report.pdf" && cmp -s "$A/bundle.zip" "$IN/bundle.zip" && ok "pdf and zip copied byte for byte" || bad "pdf/zip copy differs"
[ -d "$R/outputs/$ID" ] && ok "outputs/<task-id>/ created" || bad "no outputs/$ID"
has "task names its output folder on an outputs: line" "^outputs: $R/outputs/$ID\$" "$T"
la=$(grep -n '^## Attachments' "$T" | cut -d: -f1); lc=$(grep -n '^## Checklist' "$T" | cut -d: -f1)
[ -n "$la" ] && [ -n "$lc" ] && [ "$la" -lt "$lc" ] && ok "Attachments/Outputs sections sit before the Checklist" || bad "section order wrong (attachments $la, checklist $lc)"
has "the task tells the AI not to modify attachments" 'Do not modify, move or delete them' "$T"

echo "-- B. refusals leave nothing behind"
before=$(find "$R" | wc -l)
add "Folder" --attach "$IN/a folder" -m x > "$S/f.out" 2>&1; rcf=$?
[ "$rcf" -ne 0 ] && grep -q 'is a folder' "$S/f.out" && ok "a folder is refused with a clear message" || bad "folder not refused (rc $rcf)"
CONVEYOR_ATTACH_MAX_MB=1 bash -c 'CONVEYOR_ROOT="$0" bash "$1/conveyor" add "Big" --attach "$2" -m x' "$R" "$PKG" "$IN/big.bin" > "$S/b.out" 2>&1; rcb=$?
[ "$rcb" -ne 0 ] && grep -q 'the limit is 1 MB per file' "$S/b.out" && ok "an oversize file is refused, naming the limit" || bad "oversize not refused (rc $rcb): $(cat "$S/b.out")"
add "Missing" --attach "$IN/nope.txt" -m x > /dev/null 2>&1 && bad "a missing file was accepted" || ok "a missing file is refused"
[ "$(find "$R" | wc -l)" = "$before" ] && ok "no task, attachment or output folder left by a refused add" || bad "a refused add left files behind"

echo "-- C. plain add still works; conveyor-check hands out the folders"
newroot plain
add "No files" -m "Want: nothing" > /dev/null 2>&1
P=$(find "$R/queue" -name '*.md' | head -1)
grep -q '^## Attachments' "$P" && bad "plain task grew an Attachments section" || ok "a task with no attachments has no Attachments section"
io=$("$CHECK" --io "$P")
pid=$(basename "${P%.md}")
[ "$io" = "CONVEYOR_TASK_ID=$pid
CONVEYOR_OUTPUTS=$R/outputs/$pid
CONVEYOR_ATTACHMENTS=$R/attachments/$pid" ] && ok "conveyor-check --io names id, outputs and attachments" || bad "--io said: $io"
# Older task: no outputs: line. The folder falls back to outputs/<file stem>.
printf '# old\n\n## Checklist\n- [ ] env set :: verify: test "$CONVEYOR_OUTPUTS" = "%s/outputs/old-task" && test "$CONVEYOR_TASK_ID" = old-task\n' "$R" > "$R/queue/old-task.md"
CONVEYOR_ROOT="$R" "$CHECK" "$R/queue/old-task.md" > "$S/c.out" 2>&1 \
  && ok "verify commands see \$CONVEYOR_OUTPUTS (fallback for a task with no outputs: line)" || bad "checker env wrong: $(cat "$S/c.out")"

echo "-- D. through the belt with a stub seat"
FAKEHOME="$S/home"; mkdir -p "$FAKEHOME/.grok/bin"
STUB="$FAKEHOME/.grok/bin/grok"
cat > "$STUB" <<'SEAT'
#!/usr/bin/env bash
# Fake Grok Build: honest = uppercase the attachment into the output folder.
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
printf '%s\n' "$prompt" | grep -E '^(OUTPUT|ATTACHMENTS) FOLDER' >> "$STUBLOG"
echo "ENV_OUTPUTS=${CONVEYOR_OUTPUTS:-unset}" >> "$STUBLOG"
j() { jq -nc "$@"; }
j '{type:"system",subtype:"init",session_id:"s1",model:"grok-stub"}'
if printf '%s' "$prompt" | grep -q 'CONVEYOR VERIFIER'; then
  j --arg t "CONFIRMED: result.txt holds the uppercased input
VERDICT: pass" '{type:"result",subtype:"success",is_error:false,result:$t,session_id:"s1"}'
  exit 0
fi
att=$(printf '%s\n' "$prompt" | sed -n 's/^ATTACHMENTS FOLDER .*): //p' | head -1)
if [ "${STUB_MODE:-honest}" = honest ]; then
  tr a-z A-Z < "$att/in put.txt" > "$CONVEYOR_OUTPUTS/result.txt"
fi
j --arg t "RESULT: done — result.txt written" '{type:"result",subtype:"success",is_error:false,result:$t,session_id:"s1"}'
SEAT
chmod +x "$STUB"
# The runner wants GNU tools; on a Mac, put Homebrew's first, as ./conveyor does.
GNUPATH="$PATH"
if command -v brew >/dev/null 2>&1; then
  bp="$(brew --prefix)"
  for d in "$bp/bin" "$bp/opt/flock/bin" "$bp/opt/gnu-sed/libexec/gnubin" "$bp/opt/coreutils/libexec/gnubin"; do
    [ -d "$d" ] && GNUPATH="$d:$GNUPATH"
  done
fi
belt() {
  PATH="$GNUPATH" env -u CREW_ACTOR -u CONVEYOR_SELF -u CONVEYOR_SELF_SNAPSHOT -u CONVEYOR_GROK -u XAI_API_KEY \
      -u CONVEYOR_OUTPUTS -u CONVEYOR_ATTACHMENTS -u CONVEYOR_TASK_ID \
      HOME="$FAKEHOME" CONVEYOR_ROOT="$R" CONVEYOR_STANDALONE=1 \
      CONVEYOR_DRIVER_SEAT=grok CONVEYOR_VERIFIER_SEAT=grok CONVEYOR_LEG_CEILING=3 \
      STUBLOG="$S/stub.log" "$@" bash "$RUN" 2>&1
}
settle() { local i; for i in 1 2 3 4 5 6 7 8; do
    belt "$@" >> "$R/belt.out"
    find "$R/done" "$R/failed" -name '*.md' | grep -q . && return 0
  done; return 1; }
belttask() { # title
  add "$1" --attach "$IN/in put.txt" -m $'Want: uppercase the attachment into result.txt\n\n## Checklist\n- [ ] result.txt holds the uppercased input :: verify: grep -qx "HELLO WORLD" "$CONVEYOR_OUTPUTS/result.txt"' >/dev/null 2>&1
}
newroot e2e; : > "$S/stub.log"; belttask "Shout it"
E=$(basename "$(find "$R/queue" -name '*.md' | head -1)")
settle STUB_MODE=honest
[ -f "$R/done/$E" ] && ok "the task reached done/" || bad "not in done/ ($(find "$R" -name '*.md'))"
has "the seat's prompt named the output folder" "^OUTPUT FOLDER .*: $R/outputs/${E%.md}\$" "$S/stub.log"
has "the seat's prompt named the attachments folder" "^ATTACHMENTS FOLDER .*: $R/attachments/${E%.md}\$" "$S/stub.log"
has "the seat ran with \$CONVEYOR_OUTPUTS set" "^ENV_OUTPUTS=$R/outputs/${E%.md}\$" "$S/stub.log"
cmp -s "$R/attachments/${E%.md}/in put.txt" "$IN/in put.txt" && ok "the attachment is unchanged after the run" || bad "attachment changed"

echo "-- E. NEGATIVE CONTROL: a seat that writes no output never reaches done/"
newroot lie; belttask "Claim it"
L=$(basename "$(find "$R/queue" -name '*.md' | head -1)")
settle STUB_MODE=lie
[ -f "$R/failed/$L" ] && [ ! -f "$R/done/$L" ] && ok "the empty-output task ended in failed/" || bad "the lying task did not dead-end ($(find "$R" -name '*.md'))"

RAN=$((PASS+FAIL))
printf '\nfiles.sh: %s passed, %s failed (%s/%s assertions ran)\n' "$PASS" "$FAIL" "$RAN" "$EXPECTED"
[ "$RAN" -eq "$EXPECTED" ] || { printf 'ASSERTION COUNT WRONG — some check never ran.\n'; exit 1; }
[ "$FAIL" -eq 0 ]
