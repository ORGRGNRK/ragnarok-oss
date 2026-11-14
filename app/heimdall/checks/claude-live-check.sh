#!/bin/bash
# checks/claude-live-check.sh — bin/claude-live with a fake `claude` (no real AI): live step lines, the final reply
# printed once with its DONE:/LEFT: lines, and error results turned into a non-zero exit.
# Run from the repo folder: bash checks/claude-live-check.sh
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/claude" <<'EOF'
#!/bin/bash
case "$*" in *--output-format\ stream-json*--verbose*) ;; *) echo "wrong flags: $*" >&2; exit 9 ;; esac
cat "$FAKE_STREAM"
EOF
chmod +x "$T/claude"
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; printf '%s\n' "$out" | sed 's/^/    /'; fail=1; fi; }

cat > "$T/ok.jsonl" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/Sources/Hub.swift"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Found the warning."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x/Sources/HubOps.swift"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it.\nDONE: 1. warnings"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"Fixed it.\nDONE: 1. warnings\nLEFT: 2. needs the owner"}
EOF
out=$(FAKE_STREAM="$T/ok.jsonl" PATH="$T:$PATH" bin/claude-live -p "x" 2>&1); rc=$?
check "steps show live"      '[ $rc -eq 0 ] && printf "%s" "$out" | grep -q "^· reading Hub.swift$" && printf "%s" "$out" | grep -q "^· editing HubOps.swift$" && printf "%s" "$out" | grep -q "^· running swift build$"'
check "remarks shown"        'printf "%s" "$out" | grep -q "Found the warning."'
check "final reply once"     '[ "$(printf "%s" "$out" | grep -c "^DONE: 1. warnings$")" = 1 ] && printf "%s" "$out" | grep -q "^LEFT: 2. needs the owner$"'

printf '%s\n' '{"type":"system","subtype":"init"}' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"limit reached"}' > "$T/err.jsonl"
out=$(FAKE_STREAM="$T/err.jsonl" PATH="$T:$PATH" bin/claude-live -p "x" 2>&1); rc=$?
check "error result fails"   '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "limit reached"'

printf '#!/bin/bash\necho "boom" >&2; exit 4\n' > "$T/claude"
out=$(PATH="$T:$PATH" bin/claude-live -p "x" 2>&1); rc=$?
check "claude crash fails"   '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q boom'
exit $fail
