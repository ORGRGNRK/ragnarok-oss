# Bambu Studio on Alexus

Slicer for the Bambu Lab P1S. It runs as a web desktop in Docker, as `claude@`, from `~/bambustudio` on Alexus.

- **Use it:** open https://alexus:3001/ with Tailscale on. The browser warns about the self-signed certificate, which is expected.
- **Login:** user and password are in `~/.ragnarok/bambustudio-login` on the Mac (`user:password`, mode 600). On Alexus the
  password is in `~/bambustudio/secret/login` (mode 600). `~/bambustudio/.env` holds the user name, that file's path, and `TAILSCALE_IP` (the address the port binds to)
  (`FILE__PASSWORD=/secrets/login`), so `docker inspect` shows a path and not the password. Neither file is in git.
- **Slice without the GUI:** `ops/mac-scripts/bambu-slice MODEL.stl -o out.gcode.3mf`. Run `--help` for options.
- **Update:** change the image tag in `compose.yaml`, copy it to `~/bambustudio`, and run `docker compose up -d` there.
- **Proof:** `proof/bridge_START.gcode.3mf` is `bridge_START_gap5.5_drop7.stl` sliced for a P1S, PETG, 0.16 mm, 100% infill.
  `proof/container-env.txt` is the running container's environment, captured with `docker inspect`.

## Printer
The container is on Docker's bridge network on purpose: host networking would put the desktop on the LAN too. So automatic
printer discovery may not work. If the P1S does not appear, add it by IP with its access code, or sign in to a Bambu account.

## Reboot
**Coming back after an Alexus reboot is not proven and the fix is not installed.** Tested 2026-11-07: it recovers from a crash
(`restart: unless-stopped`), and it starts cleanly with `start-after-tailscale.sh` run by hand. A real reboot was not tried.

The container binds the Tailscale address, so it can only start once that address exists. Nothing orders Docker after Tailscale,
and at the 2026-11-01 boot Docker began loading containers at 11:45:47, a second before Tailscale reached `Starting` at 11:45:48.
So the bind can fail at boot. Whether Docker then retries it has not been tested; assume it does not.

`start-after-tailscale.sh` waits for the address and starts the container. It is on Alexus but nothing runs it at boot. Installing
the cron job was refused by a permission check, so it needs the owner. Run this as `claude@` on Alexus, then reboot once to prove it:

    (crontab -l 2>/dev/null; echo '@reboot $HOME/bambustudio/start-after-tailscale.sh >/dev/null 2>&1') | crontab -

Until then, if the page is down after a reboot, run `docker start bambustudio`.

## Security
Every account in Alexus's `docker` group (`yggdrasil`, `argon`, `grok`, `codex`, `claude`) can still read the password with
`docker exec`. Docker access is root-equivalent, so moving the file cannot stop that. Only removing accounts from the group would.

Anyone logged in can open a terminal with sudo inside the container. The image's docs call its login suitable only for a trusted
network, so keep it on Tailscale and never publish it to the internet.
