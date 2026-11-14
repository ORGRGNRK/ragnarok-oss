#!/bin/bash
# Proves ragnarok-heal tries again by itself when the test fails. No model and no network.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEAL="$ROOT/bin/ragnarok-heal"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/heal-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

make_repo() { # $1 dir $2 starting return value
  local dir="$1" value="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "heal-check"
  git -C "$dir" config user.email "heal-check@example.test"
  printf 'def hello():\n    return "%s"\n' "$value" > "$dir/app.py"
  # Read the file. Importing it can reuse a .pyc written in the same second and hide the fix.
  cat > "$dir/.ragnarok-heal" << 'EOF'
TEST=python3 -c 'import pathlib; raise SystemExit(0 if "return \"ok\"" in pathlib.Path("app.py").read_text() else 1)'
EOF
  git -C "$dir" add app.py .ragnarok-heal
  git -C "$dir" commit -qm "start"
}

cat > "$TMP/fix-on-second" << 'EOF'
#!/bin/bash
if printf '%s' "$HEAL_PROMPT" | grep -q "previous try failed"; then
  printf 'def hello():\n    return "ok"\n' > app.py
else
  printf 'def hello():\n    return "no"\n' > app.py
fi
EOF
cat > "$TMP/never-fix" << 'EOF'
#!/bin/bash
printf 'def hello():\n    return "no"\n' > app.py
EOF
chmod 700 "$TMP/fix-on-second" "$TMP/never-fix"

export HOME="$TMP/home"
mkdir -p "$HOME"

make_repo "$TMP/pass" "bad"
HEAL_SELFCHECK=1 HEAL_FAKE_CMD="$TMP/fix-on-second" \
  "$HEAL" "$TMP/pass" fake "make hello return ok" >"$TMP/pass.out" 2>&1
grep -q "round 2 of" "$TMP/pass.out"
git -C "$TMP/pass" grep -q 'return "ok"' HEAD -- app.py
test "$(git -C "$TMP/pass" rev-list --count HEAD)" = 2

make_repo "$TMP/stop" "bad"
set +e
HEAL_SELFCHECK=1 HEAL_ROUNDS=2 HEAL_FAKE_CMD="$TMP/never-fix" \
  "$HEAL" "$TMP/stop" fake "make hello return ok" >"$TMP/stop.out" 2>&1
rc=$?
set -e
test "$rc" = 1
grep -q "still failing after 2 rounds" "$TMP/stop.out"
git -C "$TMP/stop" grep -q 'return "bad"' HEAD -- app.py
test "$(git -C "$TMP/stop" rev-list --count HEAD)" = 1
echo "heal-check: ok"
