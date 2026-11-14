"""DEPRECATED (2026-10-30): the fix-memory MCP tools moved into Ragnarok's one MCP server.

`brain_search_fixes`, `brain_record_fix`, `brain_list_receipts` and `brain_verify_receipts` are now
served by ragnarok/connector (src/brain.ts), with the connector's receipting: actor required, one
access_log row per call, brain_record_fix only with a write login. Point MCP clients at the connector
(see ragnarok/connector/README.md). The old FastMCP code is in git history:
    git log --follow -- brain/fix-memory/fixloop/mcp_server.py
This stub only exists so an old `uv run fixloop-mcp` config fails with a clear message."""
from __future__ import annotations

import sys

MOVED = ("fixloop-mcp has been merged into the Ragnarok connector (ragnarok/connector). "
         "Use its brain_* tools; see ragnarok/connector/README.md. Nothing was started.")


def main() -> None:
    print(MOVED, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
