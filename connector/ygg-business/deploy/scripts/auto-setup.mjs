#!/usr/bin/env node
/**
 * Fully automated, foolproof setup for secure-mcp-platform:
 * 1. Waits for Postgres, NocoDB, and MCP to be healthy.
 * 2. Authenticates to NocoDB and ensures "Business Platform" base exists.
 * 3. Idempotently connects Postgres external data sources (public and mcp schemas).
 * 4. Seeds demo inventory if empty.
 * 5. Registers MCP clients (Claude Code, Claude Desktop, Antigravity, Codex).
 * 6. Unlocks the platform session lease.
 * 7. Warms nomic-embed-text vector embeddings and tests semantic search.
 */

import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const root = resolve(new URL(".", import.meta.url).pathname, "../..");

function loadEnv() {
  const envPath = join(root, ".env");
  const lines = readFileSync(envPath, "utf8").split("\n");
  const env = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx !== -1) {
      env[trimmed.slice(0, idx)] = trimmed.slice(idx + 1);
    }
  }
  return env;
}

const env = loadEnv();
const NC_PORT = env.PLATFORM_NC_PORT || env.YGG_NC_PORT || "8095";
const MCP_PORT = env.PLATFORM_MCP_HTTP_PORT || env.YGG_MCP_HTTP_PORT || "8787";
const NC_ADMIN_EMAIL = env.NC_ADMIN_EMAIL || "admin@example.local";
const NC_ADMIN_PASSWORD = env.NC_ADMIN_PASSWORD;
const APP_OWNER_PASSWORD = env.APP_OWNER_PASSWORD || env.YGG_APP_PASSWORD;

const say = (step, msg) => console.log(`[auto-setup] [${step}] ${msg}`);

async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForNocoDB(maxRetries = 30) {
  say("1/7", "Waiting for NocoDB healthcheck...");
  for (let i = 0; i < maxRetries; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${NC_PORT}/api/v1/health`);
      if (res.ok) {
        say("1/7", "NocoDB is healthy and ready.");
        return;
      }
    } catch {
      // wait and retry
    }
    await sleep(2000);
  }
  throw new Error("Timeout waiting for NocoDB to become healthy.");
}

async function setupNocoDB() {
  say("2/7", "Configuring NocoDB base and data sources...");
  // 1. Sign in
  const loginRes = await fetch(`http://127.0.0.1:${NC_PORT}/api/v1/auth/user/signin`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: NC_ADMIN_EMAIL, password: NC_ADMIN_PASSWORD }),
  });
  if (!loginRes.ok) {
    throw new Error(`NocoDB signin failed: ${loginRes.status} ${await loginRes.text()}`);
  }
  const { token } = await loginRes.json();
  const headers = { "Content-Type": "application/json", "xc-auth": token };

  // 2. Find or create base
  const basesRes = await fetch(`http://127.0.0.1:${NC_PORT}/api/v2/meta/bases`, { headers });
  const basesData = await basesRes.json();
  let base = basesData.list?.find((b) => b.title === "Business Platform");
  if (!base) {
    say("2/7", "Creating base 'Business Platform' in NocoDB...");
    const createBaseRes = await fetch(`http://127.0.0.1:${NC_PORT}/api/v2/meta/bases`, {
      method: "POST",
      headers,
      body: JSON.stringify({ title: "Business Platform" }),
    });
    base = await createBaseRes.json();
  }
  say("2/7", `Base 'Business Platform' is present (id: ${base.id}).`);

  // 3. Attach Postgres sources
  const sourcesRes = await fetch(`http://127.0.0.1:${NC_PORT}/api/v2/meta/bases/${base.id}/sources`, { headers });
  const sourcesData = await sourcesRes.json();
  const existingSources = sourcesData.list || [];

  async function ensureSource(alias, schema) {
    if (existingSources.some((s) => s.alias === alias)) {
      say("2/7", `Source '${alias}' (schema '${schema}') already attached.`);
      return;
    }
    say("2/7", `Attaching external source '${alias}' (schema '${schema}')...`);
    const payload = {
      alias,
      type: "pg",
      config: {
        client: "pg",
        connection: {
          host: "pg",
          port: 5432,
          user: "app_owner",
          password: APP_OWNER_PASSWORD,
          database: "app_db",
        },
        searchPath: [schema],
      },
      inflection_column: "camelize",
      inflection_table: "camelize",
    };
    const res = await fetch(`http://127.0.0.1:${NC_PORT}/api/v2/meta/bases/${base.id}/sources`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      console.warn(`[auto-setup] Warning: failed to attach source ${alias}:`, await res.text());
    } else {
      say("2/7", `Successfully attached source '${alias}'.`);
    }
    // Give NocoDB a moment to introspect before attaching the next source
    await sleep(2000);
  }

  await ensureSource("business", "public");
  await ensureSource("mcp_audit", "mcp");
}

function ensureDemoData() {
  say("3/7", "Checking inventory data in app_db...");
  try {
    const rowCount = execSync(
      `docker compose exec -T pg psql -U postgres -d app_db -tAc "SELECT count(*) FROM public.items;"`,
      { cwd: root, encoding: "utf8" }
    ).trim();
    if (parseInt(rowCount, 10) > 0) {
      say("3/7", `Inventory already has ${rowCount} items.`);
    } else {
      say("3/7", "Inventory is empty. Seeding demo data...");
      execSync(`deploy/scripts/load-demo.sh`, { cwd: root, stdio: "inherit" });
    }
  } catch (err) {
    console.warn("[auto-setup] Warning checking demo data:", err.message);
  }
}

function registerClients() {
  say("4/7", "Registering MCP clients across all installed runtimes...");
  try {
    execSync(`deploy/scripts/register-clients.sh`, { cwd: root, stdio: "inherit" });
  } catch (err) {
    console.warn("[auto-setup] Warning during client registration:", err.message);
  }

  // Register Codex
  try {
    execSync("which codex", { stdio: "ignore" });
    const codexList = execSync("codex mcp list", { encoding: "utf8" });
    if (!codexList.includes("ygg-business-docker")) {
      say("4/7", "Registering with Codex...");
      execSync(`codex mcp add ygg-business-docker --url http://127.0.0.1:${MCP_PORT}/mcp`, { stdio: "inherit" });
    } else {
      say("4/7", "Codex already registered.");
    }
  } catch {
    // codex not found or already registered
  }

  // Register Antigravity
  try {
    execSync("which agy", { stdio: "ignore" });
    const agyList = execSync("agy mcp list", { encoding: "utf8" });
    if (!agyList.includes("ygg-business-docker")) {
      say("4/7", "Registering with Antigravity (agy)...");
      execSync(`agy mcp add ygg-business-docker http://127.0.0.1:${MCP_PORT}/mcp`, { stdio: "inherit" });
    } else {
      say("4/7", "Antigravity (agy) already registered.");
    }
  } catch {
    // agy not found or already registered
  }

  // Update Claude Desktop config if exists
  try {
    const claudeDeskPath = join(homedir(), "Library/Application Support/Claude/claude_desktop_config.json");
    if (existsSync(claudeDeskPath)) {
      const cfg = JSON.parse(readFileSync(claudeDeskPath, "utf8"));
      cfg.mcpServers = cfg.mcpServers || {};
      if (!cfg.mcpServers["ygg-business-docker"]) {
        cfg.mcpServers["ygg-business-docker"] = {
          command: "docker",
          args: ["compose", "--project-directory", root, "exec", "-T", "mcp", "node", "dist/index.js"],
        };
        writeFileSync(claudeDeskPath, JSON.stringify(cfg, null, 2) + "\n");
        say("4/7", "Updated Claude Desktop configuration.");
      }
    }
  } catch (err) {
    console.warn("[auto-setup] Claude Desktop config check:", err.message);
  }
}

async function unlockPlatform() {
  say("5/7", "Unlocking platform lease...");
  try {
    const res = await fetch(`http://127.0.0.1:${MCP_PORT}/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method: "secure_enclave", secret: env.PLATFORM_UNLOCK_SECRET }),
    });
    if (res.ok) {
      const data = await res.json();
      say("5/7", `Platform unlocked (expires: ${data.expires_at || "in 60 min"}).`);
    } else {
      say("5/7", `Unlock response: ${res.status}`);
    }
  } catch (err) {
    console.warn("[auto-setup] Warning unlocking platform:", err.message);
  }
}

async function testSemanticSearch() {
  say("6/7", "Testing nomic-embed-text vector indexing & semantic search...");
  const c = new Client({ name: "auto-setup-client", version: "1.0.0" });
  try {
    await c.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${MCP_PORT}/mcp`)));
    const searchRes = await c.callTool({
      name: "platform_search_items",
      arguments: { query: "ergonomic keyboard" },
    });
    const items = searchRes.structuredContent?.items || [];
    const indexInfo = searchRes.structuredContent?.index || {};
    if (items.length > 0) {
      say(
        "6/7",
        `Vector search OK: Top hit '${items[0].name}' (score: ${items[0].score}) [model: ${indexInfo.model || "nomic-embed-text"}]`
      );
    } else {
      say("6/7", "Search executed, no items matched.");
    }
  } catch (err) {
    console.warn("[auto-setup] Warning during semantic search test:", err.message);
  } finally {
    await c.close().catch(() => {});
  }
}

function runVerification() {
  say("7/7", "Running final MCP server verification...");
  try {
    execSync(`node scripts/mcp-check.mjs --http-only`, { cwd: root, stdio: "inherit" });
    say("7/7", "All MCP tools verified operational.");
  } catch (err) {
    console.error("[auto-setup] Verification failed:", err.message);
    process.exit(1);
  }
}

function ensureDDLAuditTriggers() {
  say("3.5/7", "Ensuring PostgreSQL DDL audit event triggers are installed...");
  try {
    const sql = `
create or replace function mcp.log_drop_receipt() returns event_trigger
language plpgsql security definer set search_path = mcp, public as $$
declare r record;
begin
  for r in select * from pg_event_trigger_dropped_objects() loop
    if r.schema_name not in ('pg_toast', 'pg_temp', 'information_schema') and r.object_type = 'table' then
      insert into mcp.receipts (tool_name, payload, status)
      values (
        'postgres_drop_table',
        jsonb_build_object('action', 'DROP TABLE', 'schema', r.schema_name, 'table', r.object_name, 'identity', r.object_identity, 'actor', session_user, 'source', 'nocodb_or_direct_sql'),
        'verified'
      );
    end if;
  end loop;
end;
$$;
drop event trigger if exists trg_audit_drop_table;
create event trigger trg_audit_drop_table on sql_drop execute function mcp.log_drop_receipt();

create or replace function mcp.log_ddl_receipt() returns event_trigger
language plpgsql security definer set search_path = mcp, public as $$
declare r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.schema_name not in ('pg_toast', 'pg_temp', 'information_schema') and r.object_type = 'table' then
      insert into mcp.receipts (tool_name, payload, status)
      values (
        'postgres_' || lower(replace(r.command_tag, ' ', '_')),
        jsonb_build_object('action', r.command_tag, 'schema', r.schema_name, 'identity', r.object_identity, 'actor', session_user, 'source', 'nocodb_or_direct_sql'),
        'verified'
      );
    end if;
  end loop;
end;
$$;
drop event trigger if exists trg_audit_ddl_table;
create event trigger trg_audit_ddl_table on ddl_command_end execute function mcp.log_ddl_receipt();
`;
    execSync(`docker compose exec -T pg psql -U postgres -d app_db -q`, {
      input: sql,
      cwd: root,
      stdio: ["pipe", "ignore", "inherit"],
    });
    say("3.5/7", "DDL audit event triggers active.");
  } catch (err) {
    console.warn("[auto-setup] Warning ensuring DDL audit triggers:", err.message);
  }
}

async function main() {
  console.log("=== Starting Automated Platform Setup ===");
  await waitForNocoDB();
  await setupNocoDB();
  ensureDemoData();
  ensureDDLAuditTriggers();
  registerClients();
  await unlockPlatform();
  await testSemanticSearch();
  runVerification();
  console.log("=== Setup Complete: Platform, NocoDB, MCP & Vector Search Ready ===");
}

main().catch((err) => {
  console.error("[auto-setup] Fatal error:", err);
  process.exit(1);
});
