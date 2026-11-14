import { describe, expect, it, vi } from "vitest";
import { executeMcpToolWithReceipt } from "../../src/core/receipts.js";

describe("Hardened MCP Tool Receipt Loop (executeMcpToolWithReceipt)", () => {
  it("executes action inside a strict transaction and commits when hash chain insert succeeds", async () => {
    const executedQueries: string[] = [];
    const mockClient = {
      query: vi.fn(async (sql: string, params?: unknown[]) => {
        executedQueries.push(sql.trim());
        return { rows: [] };
      }),
    };

    const action = vi.fn(async () => ({ data: "tool-result" }));
    const result = await executeMcpToolWithReceipt(mockClient as any, "platform_test_tool", { arg: 123 }, action);

    expect(result).toEqual({ data: "tool-result" });
    expect(action).toHaveBeenCalledTimes(1);

    // Verify ordering of steps:
    // 1. BEGIN
    expect(executedQueries[0]).toBe("BEGIN");
    // 2. Advisory lock
    expect(executedQueries[1]).toContain("SELECT pg_advisory_xact_lock(hashtext($1))");
    // 3. Cryptographically chained ledger insertion
    expect(executedQueries[2]).toContain("INSERT INTO mcp.receipts (tool_name, payload, status)");
    // 4. COMMIT
    expect(executedQueries[3]).toBe("COMMIT");
  });

  it("rolls back and throws security exception if the tool action breaks", async () => {
    const executedQueries: string[] = [];
    const mockClient = {
      query: vi.fn(async (sql: string) => {
        executedQueries.push(sql.trim());
        return { rows: [] };
      }),
    };

    const failingAction = vi.fn(async () => {
      throw new Error("underlying tool execution failed");
    });

    await expect(
      executeMcpToolWithReceipt(mockClient as any, "platform_failing_tool", {}, failingAction),
    ).rejects.toThrow("Execution aborted: Cryptographic ledger validation failure.");

    expect(executedQueries[0]).toBe("BEGIN");
    expect(executedQueries[1]).toContain("SELECT pg_advisory_xact_lock");
    expect(executedQueries[2]).toBe("ROLLBACK");
  });

  it("rolls back and throws security exception if ledger insertion fails", async () => {
    const executedQueries: string[] = [];
    const mockClient = {
      query: vi.fn(async (sql: string) => {
        executedQueries.push(sql.trim());
        if (sql.includes("INSERT INTO mcp.receipts")) {
          throw new Error("Trigger violation: hash mismatch or continuity break");
        }
        return { rows: [] };
      }),
    };

    const action = vi.fn(async () => ({ ok: true }));

    await expect(
      executeMcpToolWithReceipt(mockClient as any, "platform_test_tool", {}, action),
    ).rejects.toThrow("Execution aborted: Cryptographic ledger validation failure.");

    expect(action).toHaveBeenCalledTimes(1);
    expect(executedQueries).toContain("BEGIN");
    expect(executedQueries).toContain("ROLLBACK");
    expect(executedQueries).not.toContain("COMMIT");
  });
});
