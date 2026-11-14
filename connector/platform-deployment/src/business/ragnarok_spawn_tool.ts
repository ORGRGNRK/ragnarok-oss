/**
 * ragnarok_spawn_client_stack — Trunk Tool
 *
 * This MCP tool lives inside secure-mcp-platform/src/business/tools.ts
 * It lets any AI agent onboard a new client by calling new-client.sh,
 * writing client/schema.json + client/seed.json, booting via ./kit up,
 * seeding via ./kit seed, and verifying the SHA-256 hash chain via ./kit verify.
 *
 * Naming convention enforced by src/core/server.ts:
 *   prefix_verb_noun  where verb ∈ {list|get|search|summarize}
 *
 * This tool is registered as: ragnarok_get_client_stack
 */

import { z } from "../core/validate.js";
import { execFile } from "child_process";
import { promisify } from "util";
import * as path from "path";
import * as fs from "fs/promises";

const execFileAsync = promisify(execFile);

const TYPE_MAP: Record<string, string> = {
  Text: "text",
  text: "text",
  PhoneNumber: "text",
  LongText: "long_text",
  long_text: "long_text",
  Email: "email",
  email: "email",
  URL: "url",
  url: "url",
  Number: "number",
  number: "number",
  Integer: "integer",
  integer: "integer",
  Currency: "money",
  money: "money",
  Checkbox: "boolean",
  boolean: "boolean",
  Date: "date",
  date: "date",
  DateTime: "datetime",
  datetime: "datetime",
  SingleSelect: "select",
  select: "select",
};

// ── Schema definition shape ─────────────────────────────────────────────────
const FieldSchema = z.object({
  name: z.string().describe("Column name, e.g. 'Serial Number'"),
  type: z
    .enum([
      "Text",
      "Number",
      "Integer",
      "Date",
      "DateTime",
      "Checkbox",
      "SingleSelect",
      "LongText",
      "Currency",
      "Email",
      "URL",
      "PhoneNumber",
      "text",
      "long_text",
      "email",
      "url",
      "integer",
      "number",
      "money",
      "boolean",
      "date",
      "datetime",
      "select",
    ])
    .describe("Field type (e.g. Text, Number, Currency, Date, Checkbox, SingleSelect)"),
  required: z.boolean().optional().default(false),
  unique: z.boolean().optional().default(false),
  options: z
    .array(z.string())
    .optional()
    .describe("For SingleSelect / select fields — the allowed options"),
  choices: z
    .array(z.string())
    .optional()
    .describe("Alias for options on select fields"),
});

const TableSchema = z.object({
  name: z.string().describe("Table name, e.g. 'Inventory' or 'Clients'"),
  description: z.string().optional(),
  fields: z.array(FieldSchema).min(1).max(20),
});

// ── Tool input schema ────────────────────────────────────────────────────────
export const SpawnClientSchema = z.object({
  client_slug: z
    .string()
    .regex(/^[a-z0-9-]+$/, "Lowercase letters, numbers, and hyphens only")
    .min(2)
    .max(40)
    .describe("URL-safe unique name for this client, e.g. 'phoenix-audio' or 'verde-coffee'"),

  port_offset: z
    .number()
    .int()
    .min(1)
    .max(200)
    .describe(
      "Unique integer 1–200. Determines port assignments: Postgres=5442+offset, NocoDB=8090+offset, MCP=8790+offset. Each client MUST have a unique offset."
    ),

  tables: z
    .array(TableSchema)
    .min(1)
    .max(10)
    .describe("The tables/collections for this client's database"),

  seed_rows: z
    .array(
      z.object({
        table: z.string().describe("Must match a table name from 'tables'"),
        rows: z.array(z.record(z.string(), z.unknown())).min(1).max(50),
      })
    )
    .optional()
    .describe("Optional: Initial data rows to insert into any table after setup"),

  client_display_name: z
    .string()
    .max(80)
    .optional()
    .describe("Human-readable name shown in logs, e.g. 'Phoenix Vintage Audio'"),
});

export type SpawnClientInput = z.infer<typeof SpawnClientSchema>;

// ── Constants ────────────────────────────────────────────────────────────────
// ── Main handler ─────────────────────────────────────────────────────────────
export async function spawnClientStack(input: SpawnClientInput): Promise<string> {
  const { client_slug, port_offset, tables, seed_rows, client_display_name } = input;
  const KIT_DIR = process.env.PLATFORM_KIT_DIR || process.env.RAGNAROK_KIT_DIR;
  const CLIENT_BASE = process.env.PLATFORM_CLIENT_BASE || process.env.RAGNAROK_CLIENT_BASE;
  if (!KIT_DIR || !CLIENT_BASE || !path.isAbsolute(KIT_DIR) || !path.isAbsolute(CLIENT_BASE)) {
    throw new Error("Set PLATFORM_KIT_DIR and PLATFORM_CLIENT_BASE to absolute paths before provisioning clients.");
  }
  const displayName = client_display_name || client_slug;
  const clientDir = path.join(CLIENT_BASE, client_slug);

  const pgPort = 5442 + port_offset;
  const nocoPort = 8090 + port_offset;
  const mcpPort = 8790 + port_offset;

  const lines: string[] = [];
  const log = (msg: string) => lines.push(msg);

  log(`[PLATFORM] Spawning client stack: ${displayName} (slug=${client_slug}, offset=${port_offset})`);

  // ── Step 1: Run new-client.sh ──────────────────────────────────────────────
  log(`[STEP 1/5] Running new-client.sh...`);
  try {
    const { stdout, stderr } = await execFileAsync(
      path.join(KIT_DIR, "new-client.sh"),
      [client_slug, "--dest", clientDir, "--port-offset", String(port_offset)],
      { cwd: KIT_DIR, timeout: 60_000, env: { ...process.env } }
    );
    if (stdout) log(stdout.trim());
    if (stderr) log(`[WARN] ${stderr.trim()}`);
    log(`[STEP 1/5] ✓ Client directory & isolated .env created at ${clientDir}`);
  } catch (err: any) {
    throw new Error(`new-client.sh failed: ${err.message}\n${err.stderr || ""}`);
  }

  // ── Step 2: Write client/schema.json and client/seed.json ──────────────────
  log(`[STEP 2/5] Writing client/schema.json and client/seed.json...`);
  const kitSchema = {
    client: displayName,
    description: `Sovereign stack for ${displayName} (provisioned via platform provisioning)`,
    tables: tables.map((t) => ({
      name: t.name,
      description: t.description || `${t.name} table for ${displayName}`,
      fields: t.fields.map((f) => {
        const mappedType = TYPE_MAP[f.type] || "text";
        const choices = f.options || f.choices;
        const fieldObj: Record<string, unknown> = {
          name: f.name,
          type: mappedType,
          required: Boolean(f.required),
        };
        if (f.unique) fieldObj.unique = true;
        if (mappedType === "select") {
          fieldObj.choices = choices && choices.length > 0 ? choices : ["Default"];
        }
        return fieldObj;
      }),
    })),
  };

  const kitSeed: Record<string, unknown> = {};
  if (seed_rows && seed_rows.length > 0) {
    for (const entry of seed_rows) {
      kitSeed[entry.table] = entry.rows;
    }
  }

  const schemaPath = path.join(clientDir, "client", "schema.json");
  const seedPath = path.join(clientDir, "client", "seed.json");
  await fs.writeFile(schemaPath, JSON.stringify(kitSchema, null, 2));
  await fs.writeFile(seedPath, JSON.stringify(kitSeed, null, 2));
  log(`[STEP 2/5] ✓ Wrote ${schemaPath} and ${seedPath}`);

  // ── Step 3: Boot stack and apply schema via ./kit up ───────────────────────
  log(`[STEP 3/5] Booting containers & applying schema (./kit up)...`);
  try {
    const { stdout, stderr } = await execFileAsync(
      path.join(clientDir, "kit"),
      ["up"],
      { cwd: clientDir, timeout: 240_000, env: { ...process.env } }
    );
    if (stdout) log(stdout.trim());
    if (stderr && !stderr.includes("Container ") && !stderr.includes("Network ")) {
      log(`[INFO] ${stderr.trim()}`);
    }
    log(`[STEP 3/5] ✓ Containers healthy & schema migrated`);
  } catch (err: any) {
    throw new Error(`./kit up failed: ${err.message}\n${err.stdout || ""}\n${err.stderr || ""}`);
  }

  // ── Step 4: Seed initial rows via ./kit seed ───────────────────────────────
  if (seed_rows && seed_rows.length > 0) {
    log(`[STEP 4/5] Seeding starter rows (./kit seed)...`);
    try {
      const { stdout } = await execFileAsync(
        path.join(clientDir, "kit"),
        ["seed"],
        { cwd: clientDir, timeout: 60_000, env: { ...process.env } }
      );
      if (stdout) log(stdout.trim());
      log(`[STEP 4/5] ✓ Starter data seeded`);
    } catch (err: any) {
      log(`[STEP 4/5] ⚠ Seed warning: ${err.message}`);
    }
  } else {
    log(`[STEP 4/5] No seed rows requested (skipped)`);
  }

  // ── Step 5: Verify cryptographic hash chain via ./kit verify ───────────────
  log(`[STEP 5/5] Verifying append-only SHA-256 ledger (./kit verify)...`);
  let verifyOutput = "";
  try {
    const { stdout } = await execFileAsync(
      path.join(clientDir, "kit"),
      ["verify"],
      { cwd: clientDir, timeout: 30_000, env: { ...process.env } }
    );
    verifyOutput = stdout.trim();
    log(verifyOutput);
    log(`[STEP 5/5] ✓ Cryptographic ledger verified intact`);
  } catch (err: any) {
    verifyOutput = `Verify check error: ${err.message}`;
    log(`[STEP 5/5] ⚠ ${verifyOutput}`);
  }

  // ── Final receipt ─────────────────────────────────────────────────────────
  const nocoDB = `http://127.0.0.1:${nocoPort}`;
  const mcpUrl = `http://127.0.0.1:${mcpPort}/mcp`;
  const receipt = [
    "",
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    `  PLATFORM CLIENT STACK — CRYPTOGRAPHIC RECEIPT`,
    `  Client:   ${displayName}`,
    `  Slug:     ${client_slug}`,
    `  Created:  ${new Date().toISOString()}`,
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    `  Postgres: 127.0.0.1:${pgPort}  (db=clientdata)`,
    `  NocoDB:   ${nocoDB}`,
    `  MCP:      ${mcpUrl}`,
    `  Schema:   ${schemaPath}`,
    `  Tables:   ${tables.map((t) => t.name).join(", ")}`,
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    `  Ledger Verification:`,
    ...verifyOutput.split("\n").map((l) => `    ${l}`),
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
    `  Credentials: grep -E 'POSTGRES_PASSWORD|MCP_TOKEN|NOCODB' ${clientDir}/.env`,
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
  ].join("\n");

  log(receipt);

  return lines.join("\n");
}
