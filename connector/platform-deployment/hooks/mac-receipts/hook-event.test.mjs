// node --test hooks/mac-receipts/hook-event.test.mjs — which actor and fields each AI's hook payload becomes
import { test } from "node:test";
import assert from "node:assert/strict";
import { fromHookEvent } from "./receipt.mjs";

test("Claude Code PostToolUse", () => {
  const r = fromHookEvent({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "/w", tool_name: "Bash",
    tool_input: { command: "touch x" }, tool_response: { exit_code: 0 } }, {});
  assert.equal(r.actor, "Claude Code"); assert.equal(r.command, "touch x"); assert.equal(r.exitCode, 0); assert.equal(r.source, "claude-posttooluse");
});

test("Codex apply_patch records paths without patch contents", () => {
  const patch = "*** Begin Patch\n*** Update File: src/a.ts\n+const hidden = 'secret-content';\n*** Add File: docs/new.md\n+private text\n*** End Patch";
  const r = fromHookEvent({ hook_event_name: "PostToolUse", session_id: "cx1", cwd: "/repo", tool_name: "apply_patch", tool_input: { patch } }, { CODEX_HOME: "/tmp/codex" });
  assert.equal(r.actor, "Codex");
  assert.equal(r.source, "codex-posttooluse");
  assert.match(r.target, /src\/a\.ts/);
  assert.match(r.target, /docs\/new\.md/);
  assert.doesNotMatch(r.command, /secret-content|private text/);
});
test("Grok CLI (camelCase)", () => {
  const r = fromHookEvent({ hookEventName: "PostToolUse", sessionId: "g1", toolName: "Bash", toolInput: { command: "ls" } }, {});
  assert.equal(r.actor, "Grok CLI"); assert.equal(r.session, "g1");
});
test("Gemini CLI AfterTool shell, exit code from its text output", () => {
  const r = fromHookEvent({ hook_event_name: "AfterTool", session_id: "gm", cwd: "/w", tool_name: "run_shell_command",
    tool_input: { command: "false" }, tool_response: { llmContent: "Command: false\nExit Code: 1" } }, {});
  assert.equal(r.actor, "Gemini CLI"); assert.equal(r.exitCode, 1); assert.equal(r.source, "gemini-cli-posttooluse");
});
test("Gemini CLI write_file and replace are file changes", () => {
  const w = fromHookEvent({ hook_event_name: "AfterTool", cwd: "/w", tool_name: "write_file", tool_input: { file_path: "a.txt" } }, {});
  assert.equal(w.actor, "Gemini CLI"); assert.equal(w.target, "/w/a.txt"); assert.equal(w.kind, "Change");
  const r = fromHookEvent({ hook_event_name: "AfterTool", cwd: "/w", tool_name: "replace", tool_input: { file_path: "/x/b.py" } }, {});
  assert.equal(r.target, "/x/b.py"); assert.equal(r.action, "Updated");
});
test("Antigravity run_command and file tools", () => {
  const c = fromHookEvent({ toolCall: { name: "run_command", args: { CommandLine: "npm test", Cwd: "/p" } },
    conversationId: "c1", workspacePaths: ["/p"], error: "exit status 1" }, {});
  assert.equal(c.actor, "Antigravity"); assert.equal(c.command, "npm test"); assert.equal(c.exitCode, 1); assert.equal(c.failed, true);
  assert.equal(c.session, "c1"); assert.equal(c.cwd, "/p");
  const w = fromHookEvent({ toolCall: { name: "write_to_file", args: { TargetFile: "/p/n.md" } }, conversationId: "c1" }, {});
  assert.equal(w.target, "/p/n.md"); assert.equal(w.actor, "Antigravity");
  const d = fromHookEvent({ toolCall: { name: "delete_file", args: { AbsolutePath: "/p/old" } } }, {});
  assert.equal(d.action, "Deleted");
});
test("--actor overrides, reads are ignored", () => {
  assert.equal(fromHookEvent({ hook_event_name: "AfterTool", tool_name: "run_shell_command", tool_input: { command: "ls" } }, {}, "X").actor, "X");
  assert.equal(fromHookEvent({ hook_event_name: "AfterTool", tool_name: "read_file", tool_input: { file_path: "/a" } }, {}), null);
});

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { verifyFile, remoteHost } from "./receipt.mjs";

test("read-back: Write by sha256, Edit by new_string, replace_all leftovers caught", () => {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "rcpt-")), "a.txt");
  fs.writeFileSync(f, "hello world\n");
  assert.equal(verifyFile("Write", { content: "hello world\n" }, f).ok, true);
  assert.equal(verifyFile("Write", { content: "other" }, f).ok, false);
  assert.equal(verifyFile("Edit", { old_string: "hi", new_string: "world" }, f).ok, true);
  assert.equal(verifyFile("Edit", { old_string: "x", new_string: "absent" }, f).ok, false);
  assert.equal(verifyFile("Edit", { old_string: "hello", new_string: "bye", replace_all: true }, f).ok, false);
  assert.equal(verifyFile("Edit", { old_string: "gone", new_string: "" }, f), null);
  assert.equal(verifyFile("write_file", {}, f), null);
  assert.equal(verifyFile("Write", { content: "x" }, f + ".missing").ok, false);
});
test("remote host: configured aliases only", () => {
  const before = process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS;
  try {
    delete process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS;
    assert.equal(remoteHost("ssh user@worker.example ls"), null);
    process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS = JSON.stringify({"worker.example": "worker", "192.0.2.10": "worker"});
    assert.equal(remoteHost("ssh user@worker.example 'rm x'"), "worker");
    assert.equal(remoteHost("ssh -o BatchMode=yes user@192.0.2.10 ls"), "worker");
    assert.equal(remoteHost("scp f worker.example:/tmp/"), "worker");
    assert.equal(remoteHost("rm ~/x"), null);
    assert.equal(remoteHost("ssh other.host ls"), null);
    process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS = "invalid";
    assert.equal(remoteHost("ssh worker.example ls"), null);
  } finally {
    if (before === undefined) delete process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS;
    else process.env.PLATFORM_RECEIPTS_REMOTE_HOSTS = before;
  }
});
