# Ragnarok pipe

## What it does
You take or pick a photo of a document (receipt, invoice, bill...) on your phone. The page sends it
to Alexus, where the **local** Qwen vision model (`qwen2.5vl:3b` in Ollama) reads it, pulls out the
important parts (who it's from, the date, the total, the items) and saves them in **its own Postgres
database**. Nothing leaves your network: the page is only reachable over your Tailscale tailnet.

If anything looks off (the items don't add up to the total, no date found, the model wasn't sure,
the model's answer was garbled), the document is marked **needs review**. Open it, fix the JSON in
the box and press **Approve**. **Read again** re-runs the model on the same photo.

Every step (upload, model call, checks, save, review) is written to an append-only log in the
database that can't be edited or deleted, and each row is chained by a hash so tampering is detectable.

## Open it
- On your phone or Mac (Tailscale on): **https://alexus.<tailnet>.ts.net:8448**
- Login: user and password are in `/opt/ragnarok-pipe/.env` on Alexus (`PIPE_WEB_USER`, `PIPE_WEB_PASSWORD`).
  The file is readable only by the `grok` user (mode 600).
- Speed: about 6–15 seconds per photo when the model is on the GPU; around 1.5–2 minutes if it ever runs on CPU only.

## Start / stop (on Alexus, as user `grok`)
```
systemctl --user status  ragnarok-pipe-app ragnarok-pipe-db     # are they running?
systemctl --user restart ragnarok-pipe-app                      # restart the web app
systemctl --user stop    ragnarok-pipe-app ragnarok-pipe-db     # stop everything
systemctl --user start   ragnarok-pipe-db ragnarok-pipe-app     # start again
journalctl --user -u ragnarok-pipe-app -f                       # app logs
```
Both start automatically at boot (user lingering is enabled for `grok`).

## Pieces
| Piece | Where |
|---|---|
| Web app (FastAPI) | `/opt/ragnarok-pipe/app/`, venv `.venv/`, listens on `127.0.0.1:8100` only |
| Systemd user unit | `~grok/.config/systemd/user/ragnarok-pipe-app.service` (copy in `deploy/`) |
| Postgres 16 container | `ragnarok-pipe-db` (rootless podman, user `grok`), `127.0.0.1:5544` only, volume `ragnarok-pipe-pgdata`; quadlet `~grok/.config/containers/systemd/ragnarok-pipe-db.container` |
| DB schema | `db/init/01_schema.sql` (runs once when the volume is first created) |
| Secrets | `.env` (app) and `db.env` (container), both mode 600, created by `deploy/make-env.sh`; never committed |
| Uploaded photos | `/opt/ragnarok-pipe/data/images/<sha256>.<ext>` (mode 600) |
| Tailnet access | `tailscale serve --https=8448 http://127.0.0.1:8100` (tailnet only, no Funnel) |
| Model | Ollama at `127.0.0.1:11434`, model `qwen2.5vl:3b` (set by `PIPE_MODEL` in `.env`) |

## Database
- `documents`: one row per photo: status (`processing`, `ok`, `needs_review`, `approved`, `failed`),
  type, vendor, date, subtotal, tax, total, currency, language, full transcribed text, the model's raw JSON,
  model name, latency, problems found, reviewer.
- `line_items`: the items on each document.
- `processing_log`: append-only. UPDATE/DELETE/TRUNCATE are refused by triggers (even for the owner),
  the app's DB login (`pipe_app`) only has INSERT/SELECT on it, and `SELECT * FROM processing_log_verify()`
  recomputes the hash chain and reports the first altered row (empty result = intact).
  Also available at `GET /api/log/verify`.

## API (same login)
`POST /api/upload` (form field `file`) · `GET /api/documents` · `GET /api/documents/{id}` ·
`GET /api/documents/{id}/image` · `POST /api/documents/{id}/review` (`{"fields": {...}}`) ·
`POST /api/documents/{id}/reprocess` · `GET /api/log/verify` · `GET /healthz` (needs no login)

## Tests
`tests/make_samples.py` renders clearly fake receipts (one clean English, one blurry Arabic) and
their ground truth. `PIPE_AUTH=user:pass tests/e2e.sh https://alexus.<tailnet>.ts.net:8448 tests/out/*.jpg`
uploads them and waits for the result.

## Undo everything
```
systemctl --user disable --now ragnarok-pipe-app ragnarok-pipe-db
sudo tailscale serve --https=8448 off
rm ~/.config/systemd/user/ragnarok-pipe-app.service ~/.config/containers/systemd/ragnarok-pipe-db.container
systemctl --user daemon-reload
podman volume rm ragnarok-pipe-pgdata          # deletes the database (irreversible)
sudo rm -rf /opt/ragnarok-pipe                  # deletes app, photos, secrets (irreversible)
sudo loginctl disable-linger grok               # optional: grok's services stop starting at boot
# optional: remove the vision model (run as yggdrasil):
#   sudo -u yggdrasil OLLAMA_HOST=127.0.0.1:11434 ~/.local/ollama/bin/ollama rm qwen2.5vl:3b
```
