# data/ — the filing cabinet and the logbook

## What this is

This folder is Ragnarok's **one Postgres database** plus its **receipts**.

- **The data**: the tables are described in one file, `client/schema.json`. Right now that file holds
  a made-up example shop (Products and Orders, "Example Supply Co."), so everything can be tested
  without touching real data. Swap in the real tables when you are ready.
- **The receipts**: every change to any table is written to a log called `write_log` by the database
  itself (who, when, old value, new value). Every AI tool call goes to `access_log`.
  Both logs are **hash-chained**: each row carries a fingerprint of the row before it, so if anyone
  edits or removes an old row, the check below points at the exact row. Both logs are also
  **locked**: the database refuses to edit, delete or empty them, even for the admin login.
- **No hard deletes by the AI**: the AI can only *archive* a record, and only after a person types
  `./kit approve CODE` at a real terminal and answers `yes`. Scripts, pipes and AI tools are refused.
- **Off-server anchors**: `./kit anchor` prints one line with the latest fingerprints. A Mac job
  (`scripts/mac-anchor.sh`, hourly) keeps copies of those lines, so even a full rewrite on the
  server would be caught later.
- **The doorway**: the AI never touches the database directly. It goes through the MCP server in
  `../connector/` (moved there from `data/mcp` on 2026-10-30), which receipts every call.

It came from `~/Developer/ragnarok-hq-fixes` (copied on 2026-10-30; the original is unchanged).
See `RECEIPTS.md` at the top of the repo for exactly what was copied and changed.

## What's inside

| Path | What it is |
|---|---|
| `kit` | The one command you use (`./kit` alone lists everything) |
| `docker-compose.yml` | Starts Postgres and the MCP server (the NocoDB screen only with `KIT_UI=1`). The MCP server's code lives in `../connector/`. |
| `.env.example` | Settings template. `./kit up` makes a private `.env` from it with fresh random passwords. Never share or commit `.env`. |
| `db/init/` | Database setup: logins, receipt tables, hash chain, locks, archive/approval rules |
| `db/receipts_v2.sql` | Receipt format 2 (2026-10-30): `access_log` gets `model_reported` (the model name a model API reported in its answer, when the server made the call) and `model_claimed` (what the AI client says it is; a claim). New rows are stamped `receipt_v = 2` and their hash covers both; older rows keep `receipt_v` NULL and verify exactly as before. Applied by every `./kit up` (safe to re-run). |
| `client/` | `schema.json` (your tables) and `seed.json` (starting rows). Currently the fake example. |
| `examples/inventory/` | A clean copy of the fake example, to start over from |
| `db/business.sql` | The business (resale) tables: Business, Leads, Exit Profiles, Phone Grades. Applied by every `./kit up` (safe to re-run, never deletes). AI logins can only read them; every change gets a `write_log` receipt. |
| `db/runner.sql` | The runner's receipt table (`runner.runner_events`): one row per belt step, copied from the belt's log by `runner/ragnarok/belt`. AI rows are always proposals; the AI login can add rows but not edit, delete, or write a person's approve/accept/reject (only the admin login can). Every row gets a `write_log` receipt. Applied by every `./kit up`. See `../runner/README.md`. |
| `db/run_errors.sql` | `public."Run Errors"`, the table NocoDB reads for model stderr and a PhoneGrader history file that failed to decode. The admin login adds rows. The AI logins cannot. Applied by every `./kit up`. |
| `db/brain.sql` | The brain's fix-memory tables (`brain` section: learned fixes, "fix reused" events, search vectors). Needs the pgvector add-on, which is why Postgres now runs from the `pgvector/pgvector:0.8.7-pg16-bookworm` image (still Postgres 16). Applied by every `./kit up`; AI read/write login can add fixes, never change or delete them; every fix gets a `write_log` receipt. See `../brain/README.md`. |
| `scripts/` | Helpers, tests, and the anchor scripts (`mac-anchor.sh`, `anchor-ssh-gate.sh`, `launchd/` plist) |

## How to start it

You need OrbStack (or Docker Desktop) running. Then, in Terminal:

```bash
cd ~/Developer/ragnarok/data
./kit test        # proves everything works on a throwaway copy, then deletes it. Ends with ALL TESTS PASSED
./kit up          # start it for real (first time: makes .env with fresh secrets; nothing is printed)
./kit seed        # optional: load the starting rows from client/seed.json
./kit status      # what is running, record counts, receipt check
./kit down        # stop it (data is kept)
```

The NocoDB screen is OFF by default. To start it too: `KIT_UI=1 ./kit up`.
Default ports (only reachable from this Mac): Postgres 5491, MCP 8891, NocoDB 8191 (chosen so they
never clash with ragnarok-hq's 5442/8790/8090). Change them in
`.env` if something else already uses them.

## How to verify the receipts

```bash
./kit verify
```

Good result: two lines starting with `INTACT` (one for `write_log`, one for `access_log`), each with
`lock ON`, and "all receipts intact". If you ever see `BROKEN` or `lock OFF`, the logs were changed
outside the normal path; the line says which row.

```bash
./kit anchor
```

Prints one line with the latest fingerprint ("head hash") of each log. Keep copies of these off the
server; the hourly Mac job does this for you once installed (below).
Its files are named `ragnarok-data*.jsonl`, so they never mix with the old `ragnarok-hq` anchors.

### Off-server anchors: install the hourly Mac job (not installed yet; do this only when the server runs this folder)

1. Make a dedicated key: `ssh-keygen -t ed25519 -N '' -C ragnarok-anchor -f ~/.ssh/ragnarok_anchor_ed25519` (skip if it already exists).
2. On the server, add ONE line to the owner's `~/.ssh/authorized_keys`:
   `restrict,command="~/Developer/ragnarok/data/scripts/anchor-ssh-gate.sh" ssh-ed25519 AAAA... ragnarok-anchor`
   (that key can then only run `anchor`, nothing else).
3. On the Mac: `mkdir -p ~/.local/bin && cp scripts/mac-anchor.sh ~/.local/bin/ragnarok-data-anchor.sh`
4. First run by hand: `ANCHOR_SSH_KEY=~/.ssh/ragnarok_anchor_ed25519 ~/.local/bin/ragnarok-data-anchor.sh`
5. `cp scripts/launchd/co.rgnrk.ragnarok-data.anchor.plist ~/Library/LaunchAgents/` then
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.rgnrk.ragnarok-data.anchor.plist`

The server address defaults to `<you>@alexus` (same as the old HQ setup); change
`ANCHOR_SSH_TARGET` in the plist if that is wrong. If the job ever shouts `RAGNAROK ANCHOR ALERT`,
the receipts on the server no longer match the copies on the Mac: stop and look.

## Approving an archive (the only way anything gets removed)

1. The AI asks to archive a record and gets a code like `ARC-7KQ2M9XD`.
2. You run `./kit pending` to see what is waiting, then `./kit approve ARC-7KQ2M9XD` and type `yes`.
3. The AI finishes the archive. The full record is kept in the `archive` table, and the code works once.

## Tests

- `./scripts/test-local.sh`: quick checks with no Docker (approve refuses without a terminal, anchor output, SSH gate, Mac anchor script).
- `./kit test`: the full test on a throwaway stack: the connector's 55 vitest tests (on fake business rows),
  the 66-check end-to-end test, and 11 outside checks. Optional: `TEST_PROJECT=name TEST_POSTGRES_PORT=… TEST_MCP_PORT=…` to pick the throwaway name and ports.

## Honest limits

- Someone with the admin password or full server access can switch the lock off; `./kit verify` will notice. A full rewrite of the chain is only caught by the off-server anchors.
- The "actor" name in a receipt is what the AI says it is (every tool requires one). So is `model_claimed`. Only `model_reported` comes from a model API's own answer, and only when the server itself called the model.
- The business tables start EMPTY here. Real rows (today in ygg's scratch database / Airtable) are not copied in yet. The connection type and token are recorded by the server and can't be faked.
- `./kit approve`'s terminal check stops scripts and AI tools that run commands normally. An AI with full shell access as the owner could fake a terminal, so keep AI agents on their own accounts and away from `.env`.
- Restoring from a backup (`./kit backup`) is not automated or tested yet.
