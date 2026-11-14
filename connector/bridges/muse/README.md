# muse-mcp-bridge

Lets Meta's Muse Spark (Meta Model API) use the owner's Yggdrasil v2 MCP tools, the way Claude does.
Private, local-only repo (no remote).

    npm install
    cp .env.example .env && chmod 600 .env      # then fill MODEL_API_KEY and the MCP token source
    npm run tools                                # list what Muse would get (no Muse key needed, no cost)
    npm start                                    # chat; /quit to leave
    node bridge.ts --ask "What reminders are open?"
    node bridge.ts --allow-writes                # also offer write tools; every write asks y/N first
    npm test                                     # offline tests (fake MCP server, mocked Muse)

How it works: connects to `https://mcp-server.example.com/mcp` with the Yggdrasil READ token, lists the
tools, keeps only those the server marks `readOnlyHint: true` (plus write tools with `--allow-writes`),
drops `ask_muse` / `muse_read_file` (Muse calling Muse), hides `actor` / `session` from the model and fills
them itself (`YGG_ACTOR`, default `Muse`), converts the rest to OpenAI function tools, and loops on
`POST https://api.meta.ai/v1/chat/completions` (muse-spark-1.3, reasoning_effort low, 4096-token replies,
8 tool rounds, $0.50 per session by default).

Note: with the READ token the server itself registers no write tools, so `--allow-writes` only matters with
a write-scoped token, and writes also need `Muse` on the server's actor allowlist (`config/ygg.json`).

## Muse Code (Meta's terminal agent)

Muse Code supports MCP servers in `~/.config/muse/settings.json` (`mcp_servers`, transports `stdio` or
`streamable_http`, `"schema_version": 1` required). Yggdrasil already speaks OAuth 2.1 with dynamic client
registration, so no token goes in the file: merge `muse-code-settings.example.json` into the settings file,
then run `muse mcp login yggdrasil` and approve it on the Yggdrasil approval page (owner key or Zoho sign-in;
leave "allow writes" unticked). Read-only tools then run without a prompt; others ask. `/mcp` lists them.
Bearer-token alternative: add `"headers": {"Authorization": "Bearer ${YGG_MCP_TOKEN}"}` (Muse Code
interpolates `${VAR}` from the environment).
