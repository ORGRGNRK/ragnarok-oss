// The connector's ONE MCP server. Two families of tools, one naming rule (area_verb_noun) and one
// receipt log (the data layer's hash-chained access_log):
//   data_*      the client tables from client/schema.json: read, and (write scope only) create /
//               update / archive with read-back confirmation and write_log receipts.
//   business_*  read-only views of the owner's business tables (from ygg-mcp-business), run through the
//               shared core: rate limit -> validation -> timeout -> clear errors -> redaction -> receipt.
//   brain_*     the fix memory (past test failures and their fixes; src/brain.ts). Moved here from
//               brain/fix-memory's separate `fixloop-mcp` server; same receipting as the data tools.
// In read scope the write tools are never listed (the AI can't even see them) AND the server logs
// into Postgres as the read-only user.
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema, ErrorCode, ListToolsRequestSchema, McpError,
  type CallToolResult, type Tool, type ToolAnnotations,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { createBusinessRuntime, BUSINESS_INSTRUCTIONS } from "./business/app.js";
import { loadConfig } from "./business/config.js";
import { dbConfig, type Scope } from "./config.js";
import { ToolError } from "./core/errors.js";
import { callerContext } from "./core/receipts.js";
import { pool, scrub } from "./db.js";
import { loadSchema } from "./schema.js";
import * as T from "./tools.js";
import * as B from "./brain.js";
import * as M from "./memory.js";

export const SERVER_NAME = "ragnarok-connector";
export const SERVER_VERSION = "1.0.0";

const who = {
  actor: z.string().trim().min(1).max(80).describe('Who is calling: your app/AI name, e.g. "Claude Desktop". Shown on every receipt.'),
  session: z.string().trim().min(1).max(120).optional().describe("Optional label for this conversation."),
  model_claimed: z.string().trim().min(1).max(200).optional().describe("Optional: the model you say you run on, e.g. \"claude-sonnet-4\". Stored on the receipt as model_claimed: a claim, not checked."),
};
const table = z.string().trim().min(1).max(80).describe("Table name exactly as shown by data_list_tables");
const records = z.array(z.record(z.string(), z.any())).min(1).max(50);
const note = z.string().max(500).optional().describe("Why (goes in the receipt)");

const RO: ToolAnnotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };
const RW: ToolAnnotations = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false };

type Args = Record<string, any>;
interface DataTool {
  name: string; title: string; description: string; annotations: ToolAnnotations; write: boolean;
  shape: z.ZodRawShape;
  run: (ctx: T.Ctx, a: Args) => Promise<T.Result>;
}

function dataTools(schema: ReturnType<typeof loadSchema>): DataTool[] {
  const read = (name: string, fn: (q: any, a: Args) => Promise<T.Result> | T.Result) =>
    (ctx: T.Ctx, a: Args) => T.runRead(ctx, a as T.Who, name, a, async (q) => fn(q, a));
  return [
    { name: "data_list_tables", title: "List tables", description: "List every client table with its record count.",
      shape: { ...who }, annotations: RO, write: false, run: read("data_list_tables", (q) => T.listTables(q, schema)) },
    { name: "data_describe_table", title: "Describe table", description: "Show a table's fields: type, required, unique, choices for select fields, and whether the AI may write it.",
      shape: { table, ...who }, annotations: RO, write: false, run: read("data_describe_table", (_q, a) => T.describeTable(schema, a.table)) },
    { name: "data_list_records", title: "List records",
      description: "List records from a table. Says how many matched in total, so a partial list is never mistaken for everything. Optional: fields to return, exact-match filter, sort (field name, prefix - for descending), limit (default 100, max 1000).",
      shape: {
        table, fields: z.array(z.string()).optional(),
        filter: z.record(z.string(), z.any()).optional().describe('{"Field Name": value} exact matches, all must hold'),
        sort: z.string().optional(), limit: z.number().int().min(1).max(1000).optional(), ...who,
      }, annotations: RO, write: false, run: read("data_list_records", (q, a) => T.listRecords(q, schema, a as any)) },
    { name: "data_get_record", title: "Get one record",
      description: "Get one record by its Id, or by an exact field value (refuses if more than one record matches). Includes the record's change history from the receipt log.",
      shape: { table, id: z.number().int().min(1).optional(), field: z.string().optional(), value: z.string().optional(), ...who },
      annotations: RO, write: false, run: read("data_get_record", (q, a) => T.getRecord(q, schema, a as any)) },
    { name: "data_search_records", title: "Search records", description: "Case-insensitive text search across a table's text fields (or the fields you name).",
      shape: { table, query: z.string().trim().min(1).max(200), fields: z.array(z.string()).optional(), limit: z.number().int().min(1).max(500).optional(), ...who },
      annotations: RO, write: false, run: read("data_search_records", (q, a) => T.searchRecords(q, schema, a as any)) },
    { name: "data_verify_receipts", title: "Verify receipts",
      description: "Recompute the hash chain of the receipt logs and check the append-only lock is on. Reports INTACT/BROKEN and the head hashes.",
      shape: { ...who }, annotations: RO, write: false, run: read("data_verify_receipts", (q) => T.verifyReceipts(q)) },
    { name: "data_create_records", title: "Create records",
      description: 'Create records: [{"Field Name": value}]. All-or-nothing. Every record is read back and compared field by field; only a full match is CONFIRMED. Returns a receipt per record.',
      shape: { table, records, note, ...who }, annotations: RW, write: true, run: (ctx, a) => T.createRecords(ctx, a as T.Who, schema, a as any, a as any) },
    { name: "data_update_records", title: "Update records",
      description: 'Update records by Id: [{"Id": 3, "Field Name": value}]. All-or-nothing. Read back, compared and receipted (old and new values are kept in the receipt).',
      shape: { table, records, note, ...who }, annotations: RW, write: true, run: (ctx, a) => T.updateRecords(ctx, a as T.Who, schema, a as any, a as any) },
    { name: "data_archive_record", title: "Archive (soft delete) a record",
      description: "Soft delete: copy the whole record into the archive, then remove it from the table. Needs a person's approval: the first call returns a code; the owner runs ./kit approve CODE in a terminal; call again with approval_code. There is no plain delete.",
      shape: { table, id: z.number().int().min(1), reason: z.string().trim().min(1).max(500), approval_code: z.string().trim().min(4).max(40).optional(), ...who },
      annotations: { ...RW, destructiveHint: true }, write: true, run: (ctx, a) => T.archiveRecord(ctx, a as T.Who, schema, a as any, a as any) },
    ...brainTools(),
    ...memoryTools(),
  ];
}

/** The fix memory (brain/fix-memory): formerly the separate fixloop-mcp server. */
function brainTools(): DataTool[] {
  return [
    { name: "brain_search_fixes", title: "Search stored fixes",
      description: "Find the k past fixes (error -> cause -> fix diff) whose recorded error is most similar to error_text. k is 1-10 (default 3). Uses a LOCAL embedding model; each hit carries its receipt hash.",
      shape: { error_text: z.string().min(1).max(200_000), k: z.number().int().optional(), ...who },
      annotations: RO, write: false, run: (ctx, a) => B.searchFixes(ctx, a as T.Who, a as any) },
    { name: "brain_record_fix", title: "Record a fix",
      description: "Store an error -> cause -> fix (unified diff) triple so later failures can find it. The database writes a hash-chained receipt; the fix is read back and reported CONFIRMED.",
      shape: { error_text: z.string().min(1).max(200_000), cause: z.string().max(20_000), fix: z.string().min(1).max(500_000),
        project: z.string().max(200).nullable().optional(), ...who },
      annotations: RW, write: true, run: (ctx, a) => B.recordFix(ctx, a as T.Who, a as any) },
    { name: "brain_list_receipts", title: "List brain receipts",
      description: "The most recent receipts for the fix memory (brain_fixes, brain_fix_events) from write_log, newest first. limit 1-100 (default 10).",
      shape: { limit: z.number().int().optional(), ...who }, annotations: RO, write: false, run: (ctx, a) => B.listReceipts(ctx, a as T.Who, a as any) },
    { name: "brain_verify_receipts", title: "Verify receipts (brain)",
      description: "Recompute the data layer's receipt hash chains (write_log and access_log) and report whether they are intact: {ok, checked, message}.",
      shape: { ...who }, annotations: RO, write: false, run: (ctx, a) => B.verifyBrainReceipts(ctx, a as T.Who) },
  ];
}

/** The memory layer (data/db/memory.sql; data/scripts/memory.py on the Mac). */
function memoryTools(): DataTool[] {
  const key = z.string().trim().min(1).max(200);
  return [
    { name: "memory_get_core", title: "Memory core index",
      description: "The index of what is known: titles of the current Verified and Timeless facts, one JSON line each. Titles only; read a fact with memory_get_fact before relying on it. Unchecked and Stale facts are not listed.",
      shape: { ...who }, annotations: RO, write: false, run: (ctx, a) => M.core(ctx, a as T.Who) },
    { name: "memory_get_fact", title: "Read one fact",
      description: "One fact in full by key (e.g. ygg:28): body, status, the dates it was true, source and who wrote it. Current version unless version is given.",
      shape: { key, version: z.number().int().min(1).optional(), ...who }, annotations: RO, write: false, run: (ctx, a) => M.get(ctx, a as T.Who, a as any) },
    { name: "memory_list_versions", title: "Fact history",
      description: "Every version of a fact: when each was true (valid_from -> valid_to) and who wrote it. Old versions are never deleted.",
      shape: { key, ...who }, annotations: RO, write: false, run: (ctx, a) => M.history(ctx, a as T.Who, a as any) },
    { name: "memory_search_facts", title: "Search facts",
      description: "Facts most similar in meaning to query (local embedding model). k 1-20 (default 6). Verified/Timeless only unless include_unchecked. Past chats and files are not searchable here (they live on the Mac).",
      shape: { query: z.string().trim().min(1).max(2000), k: z.number().int().optional(), include_unchecked: z.boolean().optional(), ...who },
      annotations: RO, write: false, run: (ctx, a) => M.search(ctx, a as T.Who, a as any) },
    { name: "memory_search_words", title: "Search the owner's own words",
      description: "The owner's own typed messages (verbatim, typos kept) closest in meaning to query: how they actually talk about a topic. k 1-30 (default 8). Use to match their phrasing; these are their words, not facts.",
      shape: { query: z.string().trim().min(1).max(2000), k: z.number().int().optional(), ...who }, annotations: RO, write: false, run: (ctx, a) => M.searchWords(ctx, a as T.Who, a as any) },
    { name: "memory_record_fact", title: "Remember a fact",
      description: "Add a fact, or a new version of one (same key). It ALWAYS lands Unchecked: it is not in the core index until a person or the checker verifies it. The old version keeps its text and gets an end date. Read back and receipted.",
      shape: { key, title: z.string().trim().min(1).max(300), body: z.string().trim().min(1).max(50_000), kind: z.string().max(60).optional(),
        description: z.string().max(1000).optional(), ...who }, annotations: RW, write: true, run: (ctx, a) => M.remember(ctx, a as T.Who, a as any) },
  ];
}

// ---- business runtime: one per process (shared pools + rate limiter)
let business: ReturnType<typeof createBusinessRuntime> | undefined;
function businessRuntime() {
  if (!business) {
    let app: ReturnType<typeof dbConfig> | undefined;
    try { app = dbConfig("write"); } catch { app = undefined; }
    business = createBusinessRuntime(loadConfig(), dbConfig("read"), app, (m) => console.error(`[connector] ${scrub(m)}`));
  }
  return business;
}
export async function closeBusiness() { if (business) await business.close(); }

/** Business tools take the same actor (required) and session (optional) as the data tools, so every
 *  receipt names who called. They're stripped before the business tool's own strict validation.
 *  (Over remote HTTP the MCP client's name isn't known per request, so it can't be the fallback.) */
const BIZ_WHO = {
  actor: { type: "string", minLength: 1, maxLength: 80, description: 'Who is calling: your app/AI name, e.g. "Claude Desktop". Shown on every receipt.' },
  session: { type: "string", minLength: 1, maxLength: 120, description: "Optional label for this conversation (shown on receipts)." },
  model_claimed: { type: "string", minLength: 1, maxLength: 200, description: 'Optional: the model you say you run on, e.g. "claude-sonnet-4". Stored on the receipt as model_claimed: a claim, not checked.' },
};
const withWho = (t: Tool): Tool => ({
  ...t,
  inputSchema: { ...t.inputSchema, properties: { ...(t.inputSchema.properties ?? {}), ...BIZ_WHO }, required: [...new Set([...((t.inputSchema.required as string[] | undefined) ?? []), "actor"])] },
});

const str = (v: unknown, max: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : undefined);

export function buildServer(scope: Scope, via: string, defaultSession: string): Server {
  const schema = loadSchema();
  const biz = businessRuntime();
  const data = dataTools(schema).filter((t) => scope === "write" || !t.write);
  const dataByName = new Map(data.map((t) => [t.name, t]));
  const bizListing = biz.host.listTools().map(withWho);
  const bizNames = new Set(bizListing.map((t) => t.name));
  const listing: Tool[] = [
    ...data.map((t) => {
      const js = z.toJSONSchema(z.object(t.shape), { io: "input" }) as Record<string, unknown>;
      delete js.$schema;
      return { name: t.name, title: t.title, description: t.description, inputSchema: js as Tool["inputSchema"], annotations: t.annotations };
    }),
    ...bizListing,
  ];

  const server = new Server({ name: SERVER_NAME, version: SERVER_VERSION }, {
    capabilities: { tools: {} },
    instructions: `Ragnarok connector for ${schema.client}. Client tables: ${schema.tables.map((t) => t.name).join(", ")} (data_* tools). ` +
      `${BUSINESS_INSTRUCTIONS} Fix memory: brain_search_fixes before fixing a failing test, brain_record_fix after (write scope). Memory: memory_get_core is an index of titles; memory_get_fact a fact before relying on it; memory_record_fact saves as Unchecked. Pass actor = your app name. Every call is logged in a tamper-evident receipt log; ` +
      `every write is read back and only reported CONFIRMED when the database matches, with a receipt id. ` +
      (scope === "write" ? "Deleting is a two-step soft delete (data_archive_record) that needs a code a person approves in a terminal." : "This connection is READ-ONLY."),
  });
  const clientName = () => { const cv = server.getClientVersion(); return cv ? `${cv.name}/${cv.version}` : "unknown"; };
  const ctx = (): T.Ctx => ({ scope, via, client: clientName(), defaultSession });
  const reply = (r: T.Result): CallToolResult => ({ content: [{ type: "text", text: r.text }], ...(r.data ? { structuredContent: r.data } : {}), isError: !r.ok });

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: listing }));
  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const name = req.params.name;
    const args: Args = (req.params.arguments ?? {}) as Args;

    const dt = dataByName.get(name);
    if (dt) {
      const parsed = z.object(dt.shape).safeParse(args);
      if (!parsed.success) {
        const why = parsed.error.issues.map((i) => `${i.path.length ? i.path.join(".") : "(arguments)"}: ${i.message}`).join("; ");
        const c = ctx(); const w: T.Who = { actor: str(args.actor, 80) ?? c.client, session: str(args.session, 120), model_claimed: str(args.model_claimed, 200) };
        try {
          const seq = await T.logAccess(pool(scope), c, w, name, false, args, { error: `invalid arguments: ${why}`.slice(0, 500) });
          return reply({ ok: false, text: `REFUSED -- invalid arguments for ${name}: ${why}. Nothing was changed.\n\n[access receipt: access_log #${seq}]`, data: { refused: true, access_log_seq: seq } });
        } catch (e) {
          return reply({ ok: false, text: `REFUSED -- invalid arguments for ${name}: ${why}. (Could not write the access receipt: ${scrub(e)})` });
        }
      }
      try { return reply(await dt.run(ctx(), parsed.data as Args)); }
      catch (e) { return reply({ ok: false, text: `ERROR -- ${scrub(e)} (is the database running? ./kit status)` }); }
    }

    if (bizNames.has(name)) {
      const { actor, session, model_claimed, ...rest } = args;
      const client = clientName();
      const who = str(actor, 80);
      if (!who) {   // refused like any bad argument, and still receipted
        const te = new ToolError({ code: "invalid_argument", what: `${name} needs "actor"`, why: "every call must say who is calling, so its receipt names them",
          retry_safe: true, fix: 'add actor = your app/AI name, e.g. "Claude Desktop"' });
        const c = ctx();
        const seq = await T.logAccess(pool(scope), c, { actor: client, session: str(session, 120), model_claimed: str(model_claimed, 200) }, name, false, rest, { error_code: "invalid_argument", error: te.message })
          .catch(() => undefined);
        return { isError: true, content: [{ type: "text", text: te.toText() + (seq ? `\n\n[access receipt: access_log #${seq}]` : "") }],
          structuredContent: { error: te.toJSON(), ...(seq ? { access_log_seq: seq } : {}) } };
      }
      return callerContext.run(
        { scope, via, client, actor: who, session: str(session, 120) ?? defaultSession, model_claimed: str(model_claimed, 200) },
        () => biz.host.call(name, rest),
      );
    }

    // Unknown (or, in read scope, hidden write) tool: protocol error, but still leave a receipt.
    const c = ctx();
    await T.logAccess(pool(scope), c, { actor: str(args.actor, 80) ?? c.client, session: str(args.session, 120), model_claimed: str(args.model_claimed, 200) }, name.slice(0, 80), false, {},
      { error: "unknown tool" }).catch(() => undefined);
    throw new McpError(ErrorCode.InvalidParams, `Unknown tool "${name}". Call tools/list; available tools: ${listing.map((t) => t.name).join(", ")}`);
  });
  return server;
}
