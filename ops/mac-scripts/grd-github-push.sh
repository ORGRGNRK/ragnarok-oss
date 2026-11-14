#!/bin/bash
# The owner's login on Alexus: ALEXUS_USER in ~/.ragnarok/local.conf, else this login.
OWNER="${ALEXUS_USER:-$(sed -n 's/^ALEXUS_USER=//p' "$HOME/.ragnarok/local.conf" 2>/dev/null | tail -1)}"; OWNER="${OWNER:-$(id -un)}"
# One-time, run by the owner: publishes the gnome-remote-desktop G_IO_NVAL fix
# (commit 5217c7b in ~/grd-fix/distgit on Alexus) to a public
# GitHub repo, so Fedora can take it as a remote pull request.
#   rawhide         = 2489bbb, Fedora's rawhide as of the fix (the PR base)
#   vnc-handle-nval = 5217c7b, the fix
set -euo pipefail
ssh -o ConnectTimeout=15 claude@alexus "OWNER=$OWNER bash -s" <<'EOF'
set -euo pipefail
w=$(mktemp -d); chmod 777 "$w"; trap 'rm -rf "$w"' EXIT
sudo -n -u "$OWNER" git -C "/home/$OWNER/grd-fix/distgit" bundle create "$w/grd.bundle" rawhide 2>&1 | tail -1
git clone -q "$w/grd.bundle" "$w/repo" -b rawhide
cd "$w/repo"
[ "$(git rev-parse --short HEAD)" = 5217c7b ] || { echo "unexpected HEAD $(git rev-parse --short HEAD)"; exit 1; }
gh repo view ORGRGNRK/gnome-remote-desktop-fedora >/dev/null 2>&1 ||
  gh repo create ORGRGNRK/gnome-remote-desktop-fedora --public \
    --description "Fedora dist-git branch for the gnome-remote-desktop VNC G_IO_NVAL fix (rhbz#2556851)"
gh auth setup-git
git push https://github.com/ORGRGNRK/gnome-remote-desktop-fedora.git \
  2489bbb:refs/heads/rawhide 5217c7b:refs/heads/vnc-handle-nval 2>&1 | tail -3
gh repo edit ORGRGNRK/gnome-remote-desktop-fedora --default-branch vnc-handle-nval
echo "PUSH OK"
git ls-remote https://github.com/ORGRGNRK/gnome-remote-desktop-fedora.git
EOF
