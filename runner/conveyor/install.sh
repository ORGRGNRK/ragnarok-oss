#!/usr/bin/env bash
# install.sh — arm the belt as a user systemd timer, for THIS $HOME.
#
# WHY A TEMPLATE AND NOT A SHIPPED UNIT FILE. The author's units hardcode an
# absolute path in three places each; a unit copied off another machine points
# at a directory that does not exist here and fails with a message that names
# somebody else's home. So the unit is written at install time, from where this
# script actually is.
#
# USER SCOPE, NOT SYSTEM. No sudo, nothing in /etc, and `systemctl --user`
# undoes it. A belt that hands work to an AI seat should not need root to try.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
INTERVAL="${CONVEYOR_INTERVAL:-5min}"

[ -x "$HERE/conveyor-run.sh" ] || { echo "conveyor-run.sh not found beside this script" >&2; exit 1; }

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/conveyor.service" <<UNIT
[Unit]
Description=Conveyor — hand one queued task to an AI seat
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$HERE
Environment=CONVEYOR_STANDALONE=1
Environment=CONVEYOR_ROOT=$HERE
ExecStart=$HERE/conveyor-run.sh
UNIT

cat > "$UNIT_DIR/conveyor.timer" <<UNIT
[Unit]
Description=Conveyor — run every $INTERVAL

[Timer]
OnBootSec=2min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl --user daemon-reload
echo "written: $UNIT_DIR/conveyor.service"
echo "written: $UNIT_DIR/conveyor.timer"
echo
echo "arm it:     systemctl --user enable --now conveyor.timer"
echo "watch it:   journalctl --user -u conveyor -f"
echo "stop it:    systemctl --user disable --now conveyor.timer"
echo
echo "NOT ARMED YET — enabling a loop that spends model calls is your call,"
echo "not an installer's."
