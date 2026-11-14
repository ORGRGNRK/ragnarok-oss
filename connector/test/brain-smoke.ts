// Smoke test for the brain_* tools over stdio, against a database where the fix-memory demo already
// stored fixes (brain/scripts/test-throwaway.sh runs it inside the connector image, with a real local
// Ollama). Replaces brain/fix-memory/scripts/mcp_smoke.py (the old fixloop-mcp server's smoke test).
// Exit 0 only if: 4 brain tools listed (write scope), a search finds a stored fix, the chains verify.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const ACTOR = "brain_smoke";
async function main(): Promise<boolean> {
  const transport = new StdioClientTransport({ command: "node", args: ["dist/src/stdio.js"],
    env: { ...(process.env as Record<string, string>), KIT_SCOPE: "write", MCP_USER_LABEL: "brain-smoke", MCP_HOST_LABEL: "test" }, stderr: "inherit" });
  const c = new Client({ name: "brain-smoke", version: "1.0.0" });
  await c.connect(transport);
  try {
    const names = (await c.listTools()).tools.map((t) => t.name).filter((n) => n.startsWith("brain_")).sort();
    console.log("brain tools:", names.join(", "));
    const s: any = await c.callTool({ name: "brain_search_fixes", arguments: { actor: ACTOR, error_text: "FAILED test_stats.py::test_median_odd_unsorted - assert 1 == 2", k: 2 } });
    const hits = s.structuredContent?.fixes ?? [];
    for (const h of hits) console.log("search hit:", h.id, h.source, h.similarity);
    if (s.isError) console.log(s.content?.[0]?.text);
    const v: any = await c.callTool({ name: "brain_verify_receipts", arguments: { actor: ACTOR } });
    console.log("verify:", v.structuredContent?.message);
    return names.join(",") === "brain_list_receipts,brain_record_fix,brain_search_fixes,brain_verify_receipts" && !s.isError && hits.length > 0 && v.structuredContent?.ok === true;
  } finally { await c.close(); }
}
const timer = setTimeout(() => { console.log("brain smoke test timed out"); process.exit(1); }, 180_000);
main().then((ok) => { clearTimeout(timer); process.exit(ok ? 0 : 1); }, (e) => { console.log(`brain smoke test error: ${e?.message ?? e}`); process.exit(1); });
