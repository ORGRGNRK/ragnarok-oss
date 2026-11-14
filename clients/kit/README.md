# Ragnarok client kit

A small, self-hosted "database the AI can safely use" for one client. Copy it per client, describe
their tables in one file, start it, and connect Claude.

**What you get (per client):**

| Piece | What it is for |
|---|---|
| **Postgres** | The client's data, plus a tamper-evident log of every change ("receipts"). |
| **NocoDB** (optional) | A spreadsheet-style screen so people can look at and edit the same data. |
| **MCP server** | The tools the client's AI (Claude Desktop, Claude Code, ...) uses to read and write the data. |

**The safety rules, enforced by the database itself (not just by the AI being polite):**

- **Every write is read back and receipted.** After the AI adds or changes a record, the server
  reads the record back fresh, compares every field, and only says `CONFIRMED` if all of them match.
  Each change gets a receipt (`rec_...`) in the `write_log`, with who did it, how they connected,
  the old value and the new value.
- **The receipt log is append-only and hash-chained.** Nobody, not even the admin login, can
  edit, delete or empty it through normal SQL. Each receipt contains a fingerprint (SHA-256) of the
  one before it, so if someone with full server access switches the lock off and edits a row,
  `./kit verify` (or the AI's `verify_receipts` tool) points at the exact row that was changed.
- **The AI cannot delete.** Its database login has no DELETE permission. It can only *archive* a
  record, and only after a person approves it in a terminal on the server: the AI gets a code like
  `ARC-7KQ2M9XD`, you run `./kit approve ARC-7KQ2M9XD`, then the AI can archive. The record moves to
  an `archive` table (kept whole), and the code works once.
- **Read-only is real.** The read-only token (or `KIT_SCOPE=read`) hides the write tools *and* uses
  a separate database login that can only read.
- **Remote access needs a token.** No token or a wrong token gets `401`. Tokens are never written
  to logs. Everything listens on 127.0.0.1 only; you reach it from elsewhere through a tunnel.
- **Every tool call is logged** in `access_log` (also hash-chained), including refused ones.

The AI's tools: `list_tables`, `describe_table`, `list_records`, `get_record`, `search_records`,
`verify_receipts` (always), plus `create_records`, `update_records`, `archive_record` (write access only).
They work for whatever tables `client/schema.json` describes; no code changes per client.

You need: a Mac or Linux machine with Docker (OrbStack or Docker Desktop on a Mac) and `git`.
You do not need Node installed; everything runs in containers.

---

## Set up a new client (about 10 steps)

1. Open Terminal and go to the kit: `cd ~/Developer/ragnarok-client-kit`
2. Make the client's copy: `./new-client.sh "Acme Plumbing" --port-offset 10`
   This creates `../acme-plumbing` with brand-new passwords and tokens in its own `.env`
   (nothing is printed, nothing is shared between clients) and its own ports.
   Use a different `--port-offset` (10, 20, 30, ...) for each client on the same machine.
3. Go into it: `cd ../acme-plumbing`
4. Describe the client's tables in `client/schema.json` (start from the example that is already
   there: a fake shop with Products and Orders). See `client/README.md` for field types.
5. Put any starting rows in `client/seed.json` (or make it `{}`), then run `./kit check`.
6. Prove it all works: `./kit test` (runs ~60 checks on a throwaway copy, then deletes it;
   ends with `ALL TESTS PASSED`).
7. Start it for real: `./kit up`, then `./kit seed` if you want the starting rows.
8. Connect Claude (next section). Ask it "list the tables" to check.
9. Optional: set up NocoDB so people can see the data (section below).
10. Keep copies of the receipt "head" hashes off the server: set up the hourly Mac anchor
    (section "Off-server anchors" below). They let you prove later that old receipts were not
    rewritten. Make backups with `./kit backup`.

Everyday commands (run inside the client's folder): `./kit status`, `./kit pending`,
`./kit approve CODE`, `./kit verify`, `./kit anchor`, `./kit logs`, `./kit down`, `./kit up`. Run `./kit` for the list.

Your secrets live in the client's `.env` file. Open it in a text editor when you need a token;
never paste it into chats or commit it (it is git-ignored).

---

## Connect Claude

### Same machine (stdio, simplest)

**Claude Desktop:** Settings -> Developer -> Edit Config, and add (use the real full path of the client's folder):

```json
{
  "mcpServers": {
    "acme-plumbing": {
      "command": "/Users/YOU/Developer/acme-plumbing/kit",
      "args": ["mcp-stdio"]
    }
  }
}
```

Restart Claude Desktop. For a read-only connection add `"env": { "SCOPE": "read" }` next to `"args"`.
The stack must be running (`./kit up`).

**Claude Code:**

```bash
claude mcp add acme-plumbing -- /Users/YOU/Developer/acme-plumbing/kit mcp-stdio
```

Receipts from stdio say `via stdio:<user>@<machine>`.

### From another machine (HTTP + token)

The MCP server listens on `http://127.0.0.1:<MCP_PORT>/mcp` (8790 by default, 8790+offset for
copies). To reach it from elsewhere, put a tunnel in front (below) to get an `https://` address. Then:

**Claude Code:**

```bash
claude mcp add --transport http acme-plumbing https://YOUR-ADDRESS/mcp \
  --header "Authorization: Bearer PASTE_MCP_TOKEN_OR_MCP_READ_TOKEN"
```

**Claude Desktop** (needs Node on that computer; uses the `mcp-remote` bridge):

```json
{
  "mcpServers": {
    "acme-plumbing": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://YOUR-ADDRESS/mcp",
               "--header", "Authorization:${AUTH_HEADER}"],
      "env": { "AUTH_HEADER": "Bearer PASTE_TOKEN_HERE" }
    }
  }
}
```

Give the client `MCP_READ_TOKEN` if they should only look, `MCP_TOKEN` if their AI should also
write. To change a token: put a new random value in `.env` (`openssl rand -hex 32`), then
`./kit restart`; the old one stops working right away. Leave a token empty to switch it off.
(Claude's web "custom connectors" need OAuth sign-in, which this kit does not do; use the two ways above.)

### Tunnels (documented only; the kit does not create one)

- **Tailscale** (private, only your own devices/tailnet): on the server, `tailscale serve --bg 8790`
  (use the client's MCP port). The address is `https://<machine-name>.<tailnet>.ts.net/mcp`.
- **Cloudflare Tunnel** (reachable from the internet, still token-protected): with `cloudflared`
  installed and logged in, `cloudflared tunnel create acme-mcp`, route a hostname to it
  (`cloudflared tunnel route dns acme-mcp mcp.acme.example.com`), and point it at
  `http://127.0.0.1:8790` in its config, then run it. For a quick temporary test address:
  `cloudflared tunnel --url http://127.0.0.1:8790`. Adding Cloudflare Access in front is extra protection.

Never change `BIND_ADDR` to `0.0.0.0` or open router ports; use a tunnel.

---

## NocoDB (the screen for people)

1. `./kit up` starts NocoDB too (skip it with `KIT_NO_UI=1 ./kit up`). Open `http://127.0.0.1:8090`
   (8090 + offset). The first account you create is the NocoDB owner.
2. Create a base and add a data source / "connect external database": **PostgreSQL**, host `postgres`,
   port `5432`, database `clientdata`, user `kit_ui`, password = `UI_DB_PASSWORD` from `.env`, schema `public`.
3. Hide the kit's own tables if you like (`write_log`, `access_log`, `archive`, `approvals`, `kit_tables`).

People's edits in NocoDB are receipted too (actor `kit_ui`). Deleting rows from NocoDB fails on
purpose (no delete permission); ask the AI to archive instead, or archive by hand (below).

---

## The approval flow for removing a record

1. The AI calls `archive_record` -> it answers "NOT ARCHIVED YET" and gives a code.
2. On the server, in the client folder: `./kit pending` (see what is waiting) and
   `./kit approve ARC-XXXXXXXX` (shows the record, asks you to type `yes`). There is no option to
   skip the question, and `./kit approve` refuses to run unless it is typed at a real terminal
   (it says "stdin is not a TTY" when a script, a pipe or an AI tool tries to run it).
3. The AI calls `archive_record` again with the code -> `CONFIRMED`, record moved to `archive`.

Codes expire after `APPROVAL_TTL_HOURS` (24 by default) and work once.

---

## Off-server anchors (hourly, from the Mac)

`./kit anchor` runs the same check as `./kit verify` and prints ONE JSON line: the time (UTC), whether
both logs are intact and locked, and each log's last seq number and head hash. Given the seq numbers
of an earlier anchor (`./kit anchor 120 4031`) it also prints the hash the database holds at those
seqs *now*. Exit 0 = clean, 1 = verify found a problem (the line is still printed), 2 = could not run.

`scripts/mac-anchor.sh` runs on the Mac every hour (launchd). It SSHes to the server, runs
`./kit anchor <last seqs>`, and compares with the last good anchor kept on the Mac:

- the server's verify must be clean, the seq numbers must not go **down**, and the hash at each
  previously anchored seq must be **the same**;
- good: the line is appended to `~/RAGNAROK-anchors/ragnarok-hq.jsonl` and committed to a local git
  repo there (the files get the macOS append-only flag, `chflags uappnd`);
- bad: a loud `RAGNAROK ANCHOR ALERT` on stderr (saved in `~/Library/Logs/ragnarok-hq-anchor.err.log`),
  a macOS notification, exit 2. The evidence goes to `ragnarok-hq.rejected.jsonl` and
  `ragnarok-hq.alerts.log`; the good file is left alone, so it keeps alerting every hour until you look.
- server unreachable: exit 3 and a short message (not a tamper sign).

Someone who rewrites the whole chain on the server can make `./kit verify` say INTACT, but cannot
make the old hashes kept on the Mac match. Install steps: "Install the hourly anchor" below.
`scripts/anchor-ssh-gate.sh` lets the Mac's SSH key run *only* `anchor` on the server.

### Install the hourly anchor (on the Mac)

1. Make a dedicated key (no passphrase, it can only run `anchor`):
   `ssh-keygen -t ed25519 -N '' -C ragnarok-anchor -f ~/.ssh/ragnarok_anchor_ed25519`
2. On the server, as the owner, add ONE line to `~/.ssh/authorized_keys` (paste the `.pub` key):
   `restrict,command="~/Developer/ragnarok-hq/scripts/anchor-ssh-gate.sh" ssh-ed25519 AAAA... ragnarok-anchor`
3. Test from the Mac: `ssh -i ~/.ssh/ragnarok_anchor_ed25519 -o IdentitiesOnly=yes <you>@alexus anchor`
   (prints one JSON line), and `... <you>@alexus id` (must be refused).
4. `mkdir -p ~/.local/bin && cp scripts/mac-anchor.sh ~/.local/bin/ragnarok-hq-anchor.sh`
5. First run by hand: `ANCHOR_SSH_KEY=~/.ssh/ragnarok_anchor_ed25519 ~/.local/bin/ragnarok-hq-anchor.sh`
6. `cp scripts/launchd/co.rgnrk.ragnarok-hq.anchor.plist ~/Library/LaunchAgents/` and
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.rgnrk.ragnarok-hq.anchor.plist`
   (stop it: `launchctl bootout gui/$(id -u)/co.rgnrk.ragnarok-hq.anchor`).

If you ever rebuild the database on purpose (`./kit wipe`), the next anchor will alert (seq went
down). Move the old `ragnarok-hq*.jsonl` files aside (`chflags nouappnd` first) and start fresh.

---

## Undo, restore, wipe

- **Undo a change:** every receipt has the old value. Ask the AI ("look at the history of Products #3
  and put the price back") or read it yourself in `write_log`. The fix is a new, receipted change;
  history is never rewritten.
- **Bring back an archived record:** the full record is in the `archive` table (column `record`).
  Re-create it with the AI or NocoDB from those values.
- **Backup:** `./kit backup` writes `backups/<name>-<date>.sql`, a full copy of the database
  (contains the client's data; keep it private, and keep a copy off the server). Restoring it is a
  manual job into an empty Postgres (the kit's own setup must not run first, or the receipt chain
  is rebuilt); the restore path is not automated or tested yet, so ask for help when you need it.
- **Stop, keep data:** `./kit down`.
- **Delete everything for this client:** `./kit wipe` (type the project name to confirm). Deletes the
  database, receipts and NocoDB settings. Then delete the folder to remove the copy completely.
- **Remove the kit itself:** delete `~/Developer/ragnarok-client-kit`. Nothing else on the machine
  was changed (images can be cleaned with `docker image prune`).

---

## Changing the tables later

Edit `client/schema.json`, `./kit check`, `./kit up`. New tables and fields are added; existing data
is never dropped. Removing or renaming a field in the file does not delete its column (the old
data stays in the database); a rename therefore shows up as a new empty field. Change field types
by hand only with care.

## Honest limits

- Someone with the admin password or root on the server can still switch the lock off and change
  things. They cannot do it *invisibly*: `verify` notices the lock being off and any edited or removed
  receipt. They could rewrite the whole chain from scratch, which is why the Mac keeps hourly copies
  of the head hashes off the server (step 10, "Off-server anchors"). A rewrite done between two
  anchors of rows newer than the last anchor is not caught; anything older is.
- The receipt proves what the database stored. It does not prove the AI chose the right record.
- The terminal check on `./kit approve` stops scripts, pipes and AI tools that run commands the
  normal way. An AI that runs as the server owner (or is in the `docker` group) with full shell
  access could still fake a terminal or talk to the database directly, so keep AI agents on their
  own accounts, out of the `docker` group, and away from `.env`.
- The AI's "actor" name is what the AI says it is; the connection type and token (read or full) are
  recorded by the server and cannot be faked by the AI. Use `ALLOWED_WRITE_ACTORS` to limit writers.

## What's inside

```
client/            schema.json + seed.json: the only things you edit per client
examples/inventory the fake example (Example Supply Co.)
db/init/           database setup: logins, receipts, hash chain, locks, archive/approval functions
mcp/               the MCP server (TypeScript) and its end-to-end test (mcp/test/e2e.ts)
kit                the command you use
new-client.sh      makes a fresh copy for a new client
scripts/           helpers used by kit and the test
```

Built from two earlier in-house prototypes (a Postgres + NocoDB receipt-chain kit and a demo MCP
server). No data from them was copied; the example data is made up.

## Where did the money go? (`./kit money`)

For the owner who asks "we're busy, so why is there nothing left at the end of the month?". Give it the
business's own exports and it writes a plain-English report: money in and out each month, where it goes,
and a list of leaks, biggest first. Each leak has what it's worth a month (or once), the fix, the
easiest first step, and the exact rows behind the number so the owner can check it.

```
./kit money bank.csv square-sales.csv supplier-bills.csv   # report in money-reports/<time>/report.html
./kit money add-tables                                     # once: adds Money Transactions + Money Findings
./kit money load                                           # newest report -> database (NocoDB shows it)
```

- **Files it reads:** CSV exports. Bank statements (amount, or withdrawals/deposits columns), sales from a
  POS or card processor (gross, fees, net, item/SKU, status), supplier bills (vendor, SKU, qty, unit cost).
  The kind is guessed from the column names; force it with `bank:file.csv`, `sales:` or `purchases:`.
- **What it looks for:** cash-advance pulls every day or week, overdraft and bank fees, card fees above
  about 2.9%, card sales that never reached the bank, subscriptions and price rises on them, two plans from the
  same company, charges that went through twice, items sold below cost or with thin profit, stock
  bought but not sold, unpaid invoices. "Check first" marks the ones that might be on purpose.
- **Sorting spending:** `money/rules.json` (words → group). Per client, put extra words in
  `client/money-rules.json` (same shape); they're tried first.
- **Private by design:** it only reads the files and writes the report folder (mode 700, git-ignored).
  No network. `load` goes through the database like any other write, so every row gets a receipt, and a
  row already loaded is skipped (loading overlapping statements twice doesn't double anything).
- **Try it on fake data:** `python3 money/demo/make-demo.py /tmp/demo && ./kit money /tmp/demo/*.csv`.
  The demo shop has 10 leaks planted on purpose; `python3 -I money/test_money.py` checks all 10 are found.
- **Not yet:** Excel/PDF statements (export CSV from the bank's website), pulling data straight from
  QuickBooks or Square, and amounts in currencies other than dollars.
