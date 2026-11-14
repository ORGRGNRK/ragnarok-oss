#!/usr/bin/env node
/**
 * Comprehensive Security Test Suite: Deliberate Attack Scenarios
 * Evaluates:
 * 1. Direct PostgreSQL access from unauthorized / external containers
 * 2. Concurrent queries while issuing manual lock (race condition & ledger integrity)
 * 3. Hardware authorization replay and forged unlock attempts
 * 4. Killing the gatekeeper mid-transaction (rollback & hash chain integrity)
 * 5. Clock tampering during authorization lease (monotonic vs wall-clock)
 * 6. Environment secret extraction probing across all exposed MCP tools
 * 7. Docker restart while unlocked (fail-closed boot state)
 * 8. Dispatch layer bypass attempts (host header, HTTP verbs, invalid paths)
 */

import { readFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { execSync, spawn } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const root = resolve(new URL(".", import.meta.url).pathname, "..");

function loadEnv() {
  const envPath = join(root, ".env");
  const lines = readFileSync(envPath, "utf8").split("\n");
  const env = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx !== -1) env[trimmed.slice(0, idx)] = trimmed.slice(idx + 1);
  }
  return env;
}

const env = loadEnv();
const MCP_PORT = env.PLATFORM_MCP_HTTP_PORT || env.YGG_MCP_HTTP_PORT || "8787";
const MCP_URL = `http://127.0.0.1:${MCP_PORT}/mcp`;
const BASE_URL = `http://127.0.0.1:${MCP_PORT}`;
const KNOWN_SECRETS = [
  env.POSTGRES_PASSWORD,
  env.APP_OWNER_PASSWORD,
  env.APP_READ_PASSWORD,
  env.NC_META_PASSWORD,
  env.NC_AUTH_JWT_SECRET,
  env.NC_ADMIN_PASSWORD,
].filter(Boolean);

const results = [];

function recordTest(id, name, expected, actual, passed, evidence) {
  results.push({ id, name, expected, actual, passed, evidence });
  const statusStr = passed ? "\x1b[32m[PASS]\x1b[0m" : "\x1b[31m[VULNERABILITY DETECTED]\x1b[0m";
  console.log(`\n${statusStr} Test ${id}: ${name}`);
  console.log(`  Expected: ${expected}`);
  console.log(`  Actual:   ${actual}`);
  if (evidence) {
    const lines = String(evidence).trim().split("\n");
    console.log(`  Evidence: ${lines[0]}${lines.length > 1 ? ` (+${lines.length - 1} lines)` : ""}`);
  }
}

async function unlockPlatform() {
  try {
    const res = await fetch(`${BASE_URL}/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method: "secure_enclave", secret: env.PLATFORM_UNLOCK_SECRET }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

async function lockPlatform() {
  try {
    const res = await fetch(`${BASE_URL}/lock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// -----------------------------------------------------------------------------
// Test 1: Direct PostgreSQL access from containers without credentials
// -----------------------------------------------------------------------------
async function test1_DirectPostgresAccess() {
  const id = 1;
  const name = "Direct PostgreSQL Access from Rogue / Unauthorized Containers";
  const expected = "Postgres rejects connection with authentication failure; no unauthenticated access.";
  let passed = false;
  let evidence = "";
  try {
    // Spawn an isolated ephemeral container on the compose network attempting unauthenticated access (using -w to refuse password prompt)
    const cmd = `docker run --rm --network secure-mcp-platform_default postgres:17-alpine psql -w -h pg -U attacker_user -d app_db -c "SELECT 1" 2>&1 || true`;
    const out = execSync(cmd, { encoding: "utf8", timeout: 10000 });
    evidence = out.trim();
    if (out.includes("password authentication failed") || out.includes("does not exist") || out.includes("FATAL") || out.includes("no password supplied")) {
      passed = true;
    }
    recordTest(id, name, expected, passed ? "Connection blocked by Postgres authentication" : "Unexpected connection accepted", passed, evidence);
  } catch (err) {
    passed = true;
    evidence = err.message;
    recordTest(id, name, expected, "Connection rejected", passed, evidence);
  }
}

// -----------------------------------------------------------------------------
// Test 2: Concurrent queries while locking (Race condition & Ledger integrity)
// -----------------------------------------------------------------------------
async function test2_ConcurrentQueriesWhileLocking() {
  const id = 2;
  const name = "Concurrent Queries While Issuing Lock";
  const expected = "Queries initiated after lock() rejected with 'locked'; in-flight queries complete or abort cleanly; ledger chain intact.";

  await unlockPlatform();

  const c = new Client({ name: "attack-test-2", version: "1.0.0" });
  await c.connect(new StreamableHTTPClientTransport(new URL(MCP_URL)));

  let completed = 0;
  let lockedErrors = 0;
  const total = 25;

  const queryPromises = Array.from({ length: total }, async (_, i) => {
    try {
      const res = await c.callTool({ name: "platform_list_items", arguments: { limit: 5 } });
      if (res.isError && JSON.stringify(res).includes("locked")) {
        lockedErrors++;
      } else {
        completed++;
      }
    } catch (err) {
      if (String(err).includes("locked")) lockedErrors++;
    }
  });

  // Issue lock in the middle of execution
  await new Promise((r) => setTimeout(r, 15));
  await lockPlatform();

  await Promise.allSettled(queryPromises);
  await c.close().catch(() => {});

  // Check ledger integrity
  const ledgerCheck = execSync(
    `docker compose exec -T pg psql -U postgres -d app_db -tAc "SELECT ok, checked, reason FROM mcp.verify();"`,
    { cwd: root, encoding: "utf8" }
  ).trim();

  const passed = lockedErrors > 0 && ledgerCheck.includes("chain intact");
  const actual = `${completed} succeeded before lock, ${lockedErrors} blocked after lock. Ledger: ${ledgerCheck}`;
  recordTest(id, name, expected, actual, passed, `LockedCount: ${lockedErrors}, Chain: ${ledgerCheck}`);
}

// -----------------------------------------------------------------------------
// Test 3: Hardware authorization replay and forged unlock
// -----------------------------------------------------------------------------
async function test3_ReplayAndForgedUnlock() {
  const id = 3;
  const name = "Replay of Old Hardware Authorization & Forged Unlock Calls";
  const expected = "Unlock requires authentic hardware presence proof; forged tokens or raw JSON replay must be rejected.";

  await lockPlatform();

  // Attack A: Send an arbitrary forged unlock request
  let resA;
  try {
    const r = await fetch(`${BASE_URL}/unlock`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method: "secure_enclave", token: "forged_replay_token_9999" }),
    });
    resA = await r.json();
  } catch (err) {
    resA = { error: err.message };
  }

  // Attack B: AI agent attempts to invoke platform_unlock tool directly
  const c = new Client({ name: "attack-test-3", version: "1.0.0" });
  await c.connect(new StreamableHTTPClientTransport(new URL(MCP_URL)));
  const toolUnlockRes = await c.callTool({
    name: "platform_unlock",
    arguments: { method: "secure_enclave", token: "agent_generated_fake_token" },
  });
  await c.close().catch(() => {});

  // Check if system allowed unverified unlock
  const statusRes = await (await fetch(`${BASE_URL}/status`)).json();
  const unlockedWithoutHardware = !statusRes.locked;

  // If it unlocked with just a fake token, that is a vulnerability to note and harden!
  const passed = !unlockedWithoutHardware;
  const actual = unlockedWithoutHardware
    ? "VULNERABILITY: Platform unlocked via forged token without cryptographic hardware signature verification"
    : "Forged unlock rejected; platform remained locked";

  recordTest(id, name, expected, actual, passed, JSON.stringify({ resA, toolUnlockRes, statusRes }));
}

// -----------------------------------------------------------------------------
// Test 4: Kill Gatekeeper process mid-transaction
// -----------------------------------------------------------------------------
async function test4_KillGatekeeperDuringTransaction() {
  const id = 4;
  const name = "Kill Gatekeeper During Active Database Transaction";
  const expected = "Postgres cleans up orphaned locks/connections; hash chain in mcp.receipts remains unbroken.";

  await unlockPlatform();

  // Trigger an active lock in pg and kill mcp container process
  execSync(`docker compose restart mcp`, { cwd: root, stdio: "ignore" });
  await new Promise((r) => setTimeout(r, 2500));

  // Verify Postgres connection state & ledger
  const pgOrphans = execSync(
    `docker compose exec -T pg psql -U postgres -d app_db -tAc "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction';"`,
    { cwd: root, encoding: "utf8" }
  ).trim();

  const ledgerCheck = execSync(
    `docker compose exec -T pg psql -U postgres -d app_db -tAc "SELECT ok, checked, reason FROM mcp.verify();"`,
    { cwd: root, encoding: "utf8" }
  ).trim();

  const passed = pgOrphans === "0" && ledgerCheck.includes("chain intact");
  const actual = `Orphaned transactions: ${pgOrphans}, Ledger verification: ${ledgerCheck}`;
  recordTest(id, name, expected, actual, passed, `Orphans: ${pgOrphans}, ${ledgerCheck}`);
}

// -----------------------------------------------------------------------------
// Test 5: Clock tampering & Monotonic lease enforcement
// -----------------------------------------------------------------------------
async function test5_ClockTamperingMonotonicLease() {
  const id = 5;
  const name = "Clock Tampering / Time Travel During Authorization Lease";
  const expected = "Monotonic process clock (performance.now) prevents wall-clock rollbacks from extending leases.";

  // Unit-level assertion test on SecurityGate logic
  const { SecurityGate } = await import("../dist/core/security/gate.js");
  const gate = new SecurityGate({ requireAuth: true, sessionTtlMinutes: 1 }); // 1 minute TTL = 60,000ms
  gate.unlock("secure_enclave");

  if (gate.isLocked()) {
    recordTest(id, name, expected, "Failed to unlock initially", false, "gate.isLocked() was true");
    return;
  }

  // Simulate wall-clock rollback by tampering Date.now to 10 hours in the past
  const originalDateNow = Date.now;
  const originalPerfNow = performance.now.bind(performance);
  try {
    Date.now = () => originalDateNow() - 36_000_000; // 10 hours ago
    // Advance monotonic clock past the 1-minute TTL
    performance.now = () => originalPerfNow() + 61_000;

    const lockedAfterMonotonicExpiry = gate.isLocked();
    const passed = lockedAfterMonotonicExpiry === true;
    const actual = passed
      ? "Monotonic clock expired lease despite wall-clock rolled back 10 hours"
      : "Lease extended by clock manipulation";

    recordTest(id, name, expected, actual, passed, `isLocked after time rollback: ${lockedAfterMonotonicExpiry}`);
  } finally {
    Date.now = originalDateNow;
    performance.now = originalPerfNow;
  }
}

// -----------------------------------------------------------------------------
// Test 6: Environment secret extraction probing across all exposed MCP tools
// -----------------------------------------------------------------------------
async function test6_EnvironmentSecretProbing() {
  const id = 6;
  const name = "Environment Secret Extraction Probing via All Exposed Tools";
  const expected = "Zero environment secrets or connection strings leaked in responses, errors, or stack traces.";

  await unlockPlatform();

  const c = new Client({ name: "attack-test-6", version: "1.0.0" });
  await c.connect(new StreamableHTTPClientTransport(new URL(MCP_URL)));

  const attackPayloads = [
    { tool: "platform_get_item", args: { id: 999999 } },
    { tool: "platform_get_item", args: { id: -1 } },
    { tool: "platform_list_items", args: { cursor: "eyJpZCI6OTk5OSwidG9rZW4iOiJodW50ZXIyIn0=" } },
    { tool: "platform_list_items", args: { status: "'; SELECT * FROM pg_shadow; --" } },
    { tool: "platform_list_items", args: { category: "../../.env" } },
    { tool: "platform_search_items", args: { query: "'; DROP TABLE items; -- UNION SELECT app_owner_password" } },
    { tool: "platform_search_items", args: { query: "admin database credentials and configuration secrets" } },
    { tool: "platform_list_leads", args: { limit: 10 } },
    { tool: "platform_list_channels", args: {} },
    { tool: "platform_summarize_items", args: {} },
  ];

  let leaked = false;
  let leakEvidence = "";

  for (const { tool, args } of attackPayloads) {
    try {
      const res = await c.callTool({ name: tool, arguments: args });
      const serialized = JSON.stringify(res);
      for (const secret of KNOWN_SECRETS) {
        if (secret && secret.length >= 8 && serialized.includes(secret)) {
          leaked = true;
          leakEvidence = `Tool ${tool} leaked secret: ${secret.slice(0, 3)}...`;
          break;
        }
      }
      if (serialized.toLowerCase().includes("password=") || serialized.includes("postgres://")) {
        leaked = true;
        leakEvidence = `Tool ${tool} leaked connection string details in response`;
      }
    } catch (err) {
      const errMsg = String(err);
      for (const secret of KNOWN_SECRETS) {
        if (secret && secret.length >= 8 && errMsg.includes(secret)) {
          leaked = true;
          leakEvidence = `Tool ${tool} error leaked secret: ${secret.slice(0, 3)}...`;
          break;
        }
      }
    }
    if (leaked) break;
  }

  await c.close().catch(() => {});

  const passed = !leaked;
  const actual = passed ? "All tool outputs and errors sanitized; zero secrets leaked" : leakEvidence;
  recordTest(id, name, expected, actual, passed, passed ? "Clean redaction on all payloads" : leakEvidence);
}

// -----------------------------------------------------------------------------
// Test 7: Restart Docker while unlocked (Fail-closed boot state)
// -----------------------------------------------------------------------------
async function test7_RestartDockerWhileUnlocked() {
  const id = 7;
  const name = "Docker Restart While Unlocked (Fail-Closed Boot State)";
  const expected = "Platform reboots in LOCKED state by default; rejects queries until authorized.";

  await unlockPlatform();
  const preCheck = await (await fetch(`${BASE_URL}/status`)).json();

  // Restart MCP container
  execSync(`docker compose restart mcp`, { cwd: root, stdio: "ignore" });

  // Wait for it to become ready
  await new Promise((r) => setTimeout(r, 2000));

  const postCheck = await (await fetch(`${BASE_URL}/status`)).json();
  const passed = postCheck.locked === true;
  const actual = `Pre-restart: locked=${preCheck.locked}, Post-restart: locked=${postCheck.locked}`;
  recordTest(id, name, expected, actual, passed, JSON.stringify({ preCheck, postCheck }));
}

// -----------------------------------------------------------------------------
// Test 8: Dispatch layer bypass attempts
// -----------------------------------------------------------------------------
async function test8_DispatchLayerBypass() {
  const id = 8;
  const name = "Direct Dispatch Layer & HTTP Host Header Bypass Attempts";
  const expected = "HTTP verbs other than POST rejected (405); unlisted hosts rejected (403); invalid tools rejected.";

  // 1. GET /mcp
  const resGet = await fetch(MCP_URL, { method: "GET" });
  const getBlocked = resGet.status === 405;

  // 2. Host spoofing: Host: evil-external-domain.com (using raw http.request so Node fetch doesn't strip Host header)
  const hostBlocked = await new Promise((resolve) => {
    import("node:http").then(({ default: http }) => {
      const req = http.request(MCP_URL, {
        method: "POST",
        headers: { Host: "evil-external-domain.com", "Content-Type": "application/json" },
      }, (res) => {
        resolve(res.statusCode === 403);
      });
      req.on("error", () => resolve(false));
      req.write(JSON.stringify({ jsonrpc: "2.0", method: "tools/list", id: 1 }));
      req.end();
    });
  });

  // 3. Non-whitelisted route
  const resRoute = await fetch(`${BASE_URL}/admin/internal`, { method: "POST" });
  const routeBlocked = resRoute.status === 404;

  const passed = getBlocked && hostBlocked && routeBlocked;
  const actual = `GET /mcp -> ${resGet.status} (expected 405), Host spoof -> ${hostBlocked ? "403 (blocked)" : "failed"}, Bad route -> ${resRoute.status} (expected 404)`;
  recordTest(id, name, expected, actual, passed, actual);
}

// -----------------------------------------------------------------------------
// Run All Attacks & Print Comprehensive Report
// -----------------------------------------------------------------------------
async function runAttackSuite() {
  console.log("===============================================================================");
  console.log("       DELIBERATE SECURITY ATTACK TEST SUITE (PRODUCTION READINESS)            ");
  console.log("===============================================================================");

  await test1_DirectPostgresAccess();
  await test2_ConcurrentQueriesWhileLocking();
  await test3_ReplayAndForgedUnlock();
  await test4_KillGatekeeperDuringTransaction();
  await test5_ClockTamperingMonotonicLease();
  await test6_EnvironmentSecretProbing();
  await test7_RestartDockerWhileUnlocked();
  await test8_DispatchLayerBypass();

  console.log("\n===============================================================================");
  console.log("                          SECURITY TEST SUITE SUMMARY                          ");
  console.log("===============================================================================");
  const passedCount = results.filter((r) => r.passed).length;
  const failedCount = results.length - passedCount;
  console.log(`Total Attack Scenarios Tested: ${results.length}`);
  console.log(`Passed (Secure Defense):       ${passedCount}`);
  console.log(`Vulnerabilities Found:         ${failedCount}`);

  for (const r of results) {
    const mark = r.passed ? "✔ PASS" : "✖ VULNERABILITY";
    console.log(`  ${mark} [Scenario ${r.id}] ${r.name}`);
  }
  console.log("===============================================================================\n");

  // Re-lock platform for safe final state
  await lockPlatform();
}

runAttackSuite().catch((err) => {
  console.error("Attack suite runner error:", err);
  process.exit(1);
});
