import { describe, expect, it } from "vitest";
import { mapDatabaseError, McpError, ToolError, unknownToolError } from "../../src/core/errors.js";
import { createRedactor, passwordFromUrl } from "../../src/core/redact.js";

describe("error model", () => {
  it("ToolError carries what/why/retry_safe/fix and renders actionable text", () => {
    const e = new ToolError({ code: "not_found", what: "no item 7", why: "id does not exist", retry_safe: false, fix: "list items first" });
    expect(e.toJSON()).toEqual({ code: "not_found", what: "no item 7", why: "id does not exist", retry_safe: false, fix: "list items first" });
    expect(e.toText()).toMatch(/not_found.*no item 7.*Why: id does not exist.*Retry safe: no.*Fix: list items first/);
  });

  it("unknown tools are protocol errors (McpError -32602), not tool results", () => {
    const e = unknownToolError("x_get_y", ["a_list_b"]);
    expect(e).toBeInstanceOf(McpError);
    expect(e.code).toBe(-32602);
    expect(e.message).toContain("a_list_b");
  });

  it("maps database failures to retry-safe or not", () => {
    expect(mapDatabaseError({ code: "57014" }, "q").code).toBe("timeout");
    expect(mapDatabaseError({ code: "57014" }, "q").retry_safe).toBe(true);
    expect(mapDatabaseError({ code: "ECONNREFUSED" }, "q").code).toBe("upstream_unavailable");
    expect(mapDatabaseError({ code: "42501" }, "q").retry_safe).toBe(false);
    expect(mapDatabaseError({ code: "42P01" }, "q").fix).toMatch(/\.\/kit up/);
    expect(mapDatabaseError(new Error("boom"), "q").code).toBe("internal");
  });
});

describe("redaction", () => {
  it("masks credentials in postgres URLs", () => {
    const r = createRedactor();
    expect(r.text("connect postgresql://ygg_read:hunter22@127.0.0.1:5547/db failed")).toBe(
      "connect postgresql://ygg_read:***@127.0.0.1:5547/db failed",
    );
  });

  it("masks secret-named keys and inline key=value pairs", () => {
    const r = createRedactor();
    expect(r.value({ user: "a", password: "x1", nested: { api_key: "k", token: "t", note: "password=abc123 ok" } })).toEqual({
      user: "a",
      password: "***",
      nested: { api_key: "***", token: "***", note: "password=*** ok" },
    });
  });

  it("masks configured literal secrets anywhere, including URL-encoded forms", () => {
    const r = createRedactor(["p@ss/w0rd!"]);
    expect(r.text("bad p@ss/w0rd! and p%40ss%2Fw0rd! here")).toBe("bad *** and *** here");
  });

  it("extracts and decodes the password from a URL", () => {
    expect(passwordFromUrl("postgresql://u:p%40ss@h/db")).toBe("p@ss");
    expect(passwordFromUrl("not a url")).toBeUndefined();
  });
});
