#!/bin/bash
# Alexus: (1) panes camera feed for the dashboard, (2) android-agent dependencies.
#
# panes: ORGRGNRK/panes master (the Linux build with camera slots) at
#   /srv/ragnarok/projects/src/panes, owned by a `panes` system user in group video.
#   panes-web.service     server.py on 127.0.0.1:8081 (what the dashboard's PANES_URL expects)
#   panes-camera.service  camera-pusher.sh -> C920 on /dev/video0 as cam slot "desk"
# android-agent: system adb (android-tools ships its own udev rules), and a git worktree of the unmerged branch
#   claude/android-agent-slice-1 at /srv/ragnarok/projects/src/ALEXUS-android-agent
#   with its npm dependencies installed, built and tested.
set -euo pipefail
ssh -o ConnectTimeout=15 claude@alexus 'bash -s' <<'EOF'
set -euo pipefail
echo "== packages"
sudo -n dnf install -y -q android-tools v4l-utils >/dev/null
rpm -q android-tools v4l-utils

echo "== panes user + code"
P=/srv/ragnarok/projects/src/panes
id panes >/dev/null 2>&1 || sudo -n useradd --system --home-dir "$P" --no-create-home --shell /sbin/nologin panes
sudo -n usermod -aG video panes
if [ ! -d "$P/.git" ]; then
  t=$(mktemp -d); git clone -q -b master https://github.com/ORGRGNRK/panes.git "$t/panes"
  sudo -n mv "$t/panes" "$P"; rmdir "$t"
fi
sudo -n mkdir -p "$P/frames"
sudo -n chown -R panes:panes "$P"
sudo -n git -c safe.directory='*' -C "$P" log --oneline -1

echo "== units"
sudo -n tee /etc/systemd/system/panes-web.service >/dev/null <<UNIT
[Unit]
Description=panes: frame receiver + static page on 127.0.0.1:8081 (dashboard camera feeds)
After=network.target

[Service]
User=panes
Group=panes
WorkingDirectory=$P
ExecStart=/usr/bin/python3 $P/server.py --port 8081 --bind 127.0.0.1 --directory $P
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo -n tee /etc/systemd/system/panes-camera.service >/dev/null <<UNIT
[Unit]
Description=panes: C920 webcam -> panes /frame as cam slot "desk"
After=panes-web.service
Wants=panes-web.service

[Service]
User=panes
Group=panes
SupplementaryGroups=video
WorkingDirectory=$P
Environment=HOME=/srv/ragnarok/projects/src
Environment=PUSH_DEVICE=/dev/video0
Environment=PUSH_CAM=desk
Environment=PUSH_TMP=$P/frames/.pusher.jpg
ExecStart=/bin/bash $P/camera-pusher.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
sudo -n systemctl daemon-reload
sudo -n systemctl enable --now panes-web.service panes-camera.service
sleep 25
systemctl is-active panes-web panes-camera
curl -s -m5 "http://127.0.0.1:8081/frame/meta?cam=desk"; echo
curl -s -m5 http://127.0.0.1:4200/api/camera/feed/desk/meta; echo

echo "== android-agent"
S=/srv/ragnarok/projects/src/ALEXUS; W=/srv/ragnarok/projects/src/ALEXUS-android-agent
G="sudo -n -u yggdrasil git -c safe.directory=* -C $S"
[ -d "$W" ] || $G worktree add -q "$W" claude/android-agent-slice-1 2>/dev/null || $G worktree add -q "$W" -b claude/android-agent-slice-1 origin/claude/android-agent-slice-1
cd "$W"
sudo -n -u yggdrasil npm install --no-audit --no-fund --loglevel=error --workspace=@alexus/android-agent 2>&1 | tail -3
cd packages/android-agent
sudo -n -u yggdrasil npm run --silent build 2>&1 | tail -3 && echo "build OK"
sudo -n -u yggdrasil npm test 2>&1 | grep -E "^# (tests|pass|fail)" || true
adb version | head -1
sudo -n -u yggdrasil adb devices -l
echo "SETUP OK"
EOF
