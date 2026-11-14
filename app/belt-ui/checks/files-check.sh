#!/bin/bash
# Builds and runs checks/files-check.swift. No real SSH, no AI, nothing
# outside a temp folder is written (the local belt is a copy of ~/conveyor's
# scripts; the "remote" belt holds the PRE-attach conveyor-add from the backup,
# changed to write into the wrong folder like Alexus's copy, which the app
# must never call).
set -eu
cd "$(dirname "$0")/.."
BELT="${BELT:-$HOME/conveyor}"
OLD_ADD="${OLD_ADD:-$HOME/conveyor-backup-20261026-files/conveyor-add}"
S="$(mktemp -d)"; trap 'chmod -R u+w "$S"; rm -rf "$S"' EXIT
mkdir -p "$S/local" "$S/remote"/{queue,human,logs}
for f in conveyor conveyor-add conveyor-check; do cp "$BELT/$f" "$S/local/"; done
mkdir -p "$S/local"/{queue,running,verify,human,done,failed,logs}
cp "$OLD_ADD" "$S/remote/conveyor-add"
# Like the copy on Alexus: it ignores CONVEYOR_ROOT and writes into another
# folder's queue. The app must not use it (it writes queue/<id>.md itself).
sed -i '' 's|^QUEUE=.*|QUEUE="$WRONG_QUEUE"|' "$S/remote/conveyor-add"
grep -q '^QUEUE="$WRONG_QUEUE"' "$S/remote/conveyor-add" || { echo "could not make the stand-in conveyor-add"; exit 1; }
mkdir -p "$S/wrong-home/queue" "$S/oldlocal"
# A task written by the CLI, for the parser.
printf 'one\n' > "$S/one.txt"; printf 'two\n' > "$S/two.csv"
CONVEYOR_ROOT="$S/local" bash "$S/local/conveyor" add "cli made" --attach "$S/one.txt" --attach "$S/two.csv" -m "Want: z" >/dev/null
CLI_TASK="$(ls "$S"/local/queue/*cli-made*.md)"
cat > "$S/fake-ssh" <<'SSH'
#!/bin/bash
# Fake ssh: ignore options and host, run the last argument with local bash.
script="${!#}"
PATH="$GNUPATH" exec bash -c "$script"
SSH
chmod +x "$S/fake-ssh"
GNUPATH="$PATH"
if command -v brew >/dev/null; then bp=$(brew --prefix); GNUPATH="$bp/opt/coreutils/libexec/gnubin:$bp/opt/gnu-sed/libexec/gnubin:$PATH"; fi
swiftc -O -o "$S/files-check" checks/files-check.swift Sources/Conveyor/Belt.swift Sources/Conveyor/Remote.swift Sources/Conveyor/Files.swift -parse-as-library 2>&1 | grep -v '^$' || true
[ -x "$S/files-check" ] || { echo "compile failed"; exit 1; }
# The older-format task is a real one on this belt; it moves between trays, so
# find it in whichever tray it is in now (read only).
if [ -z "${LEGACY_TASK:-}" ]; then
  for tray in human queue running verify done failed plan; do
    [ -f "$BELT/$tray/20261026-080258-read-column-names-from-a-screenshot.md" ] && { LEGACY_TASK="$BELT/$tray/20261026-080258-read-column-names-from-a-screenshot.md"; break; }
  done
fi
WRONG_QUEUE="$S/wrong-home/queue" OLD_LOCAL="$S/oldlocal" SCRATCH="$S" REMOTE_BELT="$S/remote" LOCAL_BELT="$S/local" CLI_TASK="$CLI_TASK" GNUPATH="$GNUPATH" PATH="$GNUPATH" \
  LEGACY_TASK="${LEGACY_TASK:-}" \
  CONVEYOR_SSH="$S/fake-ssh" "$S/files-check"
