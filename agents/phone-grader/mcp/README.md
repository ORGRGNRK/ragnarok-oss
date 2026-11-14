# PhoneGrader MCP server

A local **stdio** MCP server that makes PhoneGrader the memory store for the phone-flipping business.
Every tool shells out to `PhoneGrader --cli … --json` (the installed app's own binary), so the app's
logic and `~/Library/Application Support/PhoneGrader/history.json` stay the single source of truth.

- Read: `list_phones` (status listed/sold/unsold/unlisted, model search), `get_phone`, `business_stats`,
  `list_phone_notes`, `list_business_notes`, `parts_log_list`
- Write (explicit, no delete tools): `set_listing_price`, `record_purchase_price`, `record_listing_stats`,
  `mark_sold`, `mark_unsold`, `add_phone_note`, `add_business_note`, `parts_log_add`
- Notes are append-only. Dates (`at`) accept local `"2026-10-16 19:30"` or ISO 8601.
- **Private data:** Atlas floor, max buy, deal breakdown, purchase price and actual profit are returned under
  a `private` key with a note. They are for the owner only, never for listings, buyer messages or receipts.

## Setup

```sh
cd ~/Developer/phone-grader-app/mcp
PATH="$HOME/.local/node/bin:$PATH" npm install
```
Requires the current app installed at `~/Applications/PhoneGrader.app` (`./build.sh`, then copy `dist/PhoneGrader.app`).
Env: `PHONEGRADER_BIN` (another binary), `PHONEGRADER_DATA_DIR` (another data folder; tests use a temp one).

## Claude Desktop

`~/Library/Application Support/Claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "phonegrader": {
      "command": "~/.local/node/bin/node",
      "args": ["~/Developer/phone-grader-app/mcp/server.mjs"]
    }
  }
}
```
Restart Claude Desktop.

## Claude Code

```sh
claude mcp add --scope user phonegrader -- ~/.local/node/bin/node ~/Developer/phone-grader-app/mcp/server.mjs
```
(or put the same `mcpServers` JSON in a project `.mcp.json`).

## LM Studio

Program → Install → Edit `mcp.json` (`~/.lmstudio/mcp.json`), same format:
```json
{
  "mcpServers": {
    "phonegrader": {
      "command": "~/.local/node/bin/node",
      "args": ["~/Developer/phone-grader-app/mcp/server.mjs"]
    }
  }
}
```

## Tests

```sh
swift build                       # from the repo root; tests use .build/debug/PhoneGrader
cd mcp && PATH="$HOME/.local/node/bin:$PATH" npm test
```
The smoke tests run the server against a temporary copy of history (`PHONEGRADER_DATA_DIR`) and check the real history.json is untouched.
