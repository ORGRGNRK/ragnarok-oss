import { describe, expect, it } from "vitest";
import { SecurityGate } from "../../src/core/security/gate.js";
import { ToolHost } from "../../src/core/server.js";
import { TokenBucket } from "../../src/core/rate-limit.js";
import { createRedactor } from "../../src/core/redact.js";
import { defineTool } from "../../src/core/server.js";
import { z } from "../../src/core/validate.js";

describe("SecurityGate & Boot-Lock Mechanism", () => {
  it("defaults to locked on initialization", () => {
    const gate = new SecurityGate({ requireAuth: true });
    expect(gate.isLocked()).toBe(true);
    const status = gate.getStatus();
    expect(status.locked).toBe(true);
    expect(status.method).toBe(null);
  });

  it("can be unlocked with yubikey or secure_enclave and auto-expires", () => {
    const gate = new SecurityGate({ requireAuth: true, sessionTtlMinutes: 30 });
    expect(gate.isLocked()).toBe(true);

    const unlockResult = gate.unlock("yubikey");
    expect(unlockResult.success).toBe(true);
    expect(gate.isLocked()).toBe(false);

    let status = gate.getStatus();
    expect(status.locked).toBe(false);
    expect(status.method).toBe("yubikey");
    expect(status.remainingMinutes).toBeGreaterThanOrEqual(29);

    // Switch to Apple Secure Enclave
    gate.unlock("secure_enclave");
    status = gate.getStatus();
    expect(status.method).toBe("secure_enclave");

    // Can be manually locked
    gate.lock();
    expect(gate.isLocked()).toBe(true);
  });

  it("blocks regular tool dispatch when locked, but allows status/unlock tools", async () => {
    const gate = new SecurityGate({ requireAuth: true });
    const redactor = createRedactor([]);
    const receipts = { write: async () => {} };
    const limiter = new TokenBucket({ capacity: 10, refillPerSecond: 10 });

    const regularTool = defineTool({
      name: "platform_list_items",
      description: "List items",
      input: z.object({}).strict(),
      async handler() {
        return { summary: "ok", data: { items: [] } };
      },
    });

    const statusTool = defineTool({
      name: "platform_status",
      description: "Status",
      input: z.object({}).strict(),
      allowWhileLocked: true,
      async handler() {
        return { summary: "status ok", data: gate.getStatus() };
      },
    });

    const host = new ToolHost({
      name: "test-host",
      version: "1.0.0",
      tools: [regularTool, statusTool],
      limiter,
      receipts,
      redactor,
      securityGate: gate,
      defaultTimeoutMs: 1000,
    });

    // 1. Regular tool fails closed with locked error
    const regularResult = await host.call("platform_list_items", {});
    expect(regularResult.isError).toBe(true);
    expect((regularResult.structuredContent as any)?.error?.code).toBe("locked");

    // 2. Status tool succeeds even while locked
    const statusResult = await host.call("platform_status", {});
    expect(statusResult.isError).toBe(undefined);
    expect((statusResult.structuredContent as any)?.locked).toBe(true);

    // 3. Unlock gate
    gate.unlock("secure_enclave");
    expect(gate.isLocked()).toBe(false);

    // 4. Regular tool now executes normally
    const unlockedResult = await host.call("platform_list_items", {});
    expect(unlockedResult.isError).toBe(undefined);
    expect((unlockedResult.structuredContent as any)?.items).toEqual([]);
  });
});
