# Intake

One place for text, files and photos sent by the owner or by any of their AIs. Heimdall's Intake tab is the screen. The database is this client's own Postgres, started with the shared kit. There is one MCP server, the kit's, with `ingest` and `search` added for this schema only.

File bytes live in `blobs/` inside this folder on Alexus (the root disk). Postgres stores the record and the sha256, not the bytes. The same sha256 is one file. A file over 5 GB is refused. New uploads are refused when that disk would drop below 10 GB free. Both limits are in `.env`.

`.env` is created on Alexus by `clients/kit/new-client.sh` and is not in git. Do not point the blob directory at `/mnt/seagate`.

```
./kit up          start Postgres and the MCP (KIT_NO_UI=1 skips the spreadsheet)
./kit status
./kit verify
```

Postgres stays on 127.0.0.1. The HTTP door is also on 127.0.0.1, and `.env` publishes that same MCP port on the Tailscale address only (`INTAKE_TAILSCALE_BIND`). It is not on the public internet and not on the home-network address. `tailscale serve` would do this without a second bind, and it needs root.

Send from a machine that has `~/.ragnarok/intake.env` (`URL` and `TOKEN`):

```
app/heimdall/bin/ragnarok-intake "a note"
app/heimdall/bin/ragnarok-intake path/to/file-or-photo
app/heimdall/bin/ragnarok-intake --search "note"
```

Ingest pipe (always on, Mac): `app/heimdall/bin/ragnarok-ingest --install` watches `~/Intake`; anything dropped there is sent through `ragnarok-intake`, then moved to `~/Intake/.sent/` (refused ones to `.failed/` with a `.why`; kept in place while Alexus is down). `cmd | ragnarok-ingest -` sends stdin as one text item. Receipts: `~/.ragnarok/ingest.jsonl`. `--status` checks it.

Sorter (Alexus, every 2 min): `sorter/intake-sorter.py` has the local vision model (`qwen2.5vl:7b` in the `ragnarok-ollama` container) look at each new photo and writes Tags (`sorted`, `cat:…`, `brand:…`), Project `selling`, a listing-style Title (only over a bare filename) and an "AI guess" Body (only if empty), through `update_records`, so every change is receipted. A photo it cannot read gets `sort-failed`. Runs from the `~/Developer/ragnarok` checkout; units are linked from `sorter/`. `--dry-run` and `--id N` for testing; `journalctl --user -u intake-sorter` for what it did.

The MCP tools are `ingest` (text, or a small file as base64) and `search`. Large files go through the HTTP door or the CLI. Nothing sent in is run.
