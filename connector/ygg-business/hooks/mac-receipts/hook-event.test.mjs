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
test("--actor overrides, reads retain metadata only", () => {
  assert.equal(fromHookEvent({ hook_event_name: "AfterTool", tool_name: "run_shell_command", tool_input: { command: "ls" } }, {}, "X").actor, "X");
  const read=fromHookEvent({ hook_event_name: "AfterTool", tool_name: "read_file", tool_input: { file_path: "/a", secret:"private input" } }, {});
  assert.equal(read.kind,"Read");assert.doesNotMatch(JSON.stringify(read),/private input/);
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
test("remote host: ssh/scp to Alexus by any name, else this Mac", () => {
  assert.equal(remoteHost("ssh sam@alexus 'rm x'"), "alexus");
  assert.equal(remoteHost("ssh -o BatchMode=yes alexus.example.ts.net ls"), "alexus");
  assert.equal(remoteHost("scp f alexus:/tmp/"), "alexus");
  assert.equal(remoteHost("rm ~/x"), null);
  assert.equal(remoteHost("ssh other.host ls"), null);
});

test("explicit Codex hook identity survives a stripped environment", () => {
  const event = { hook_event_name: "PostToolUse", session_id: "cx", tool_name: "Bash", tool_input: { command: "pwd" }, tool_response: { exit_code: 0 } };
  const result = fromHookEvent(event, {}, "Codex");
  assert.equal(result.actor, "Codex");
  assert.equal(result.source, "codex-posttooluse");
  assert.equal(result.session, "cx");
  assert.equal(result.command, "pwd");
  const failed = fromHookEvent({ ...event, hook_event_name: "PostToolUseFailure" }, {}, "Codex");
  assert.equal(failed.source, "codex-posttoolusefailure");
});

import { isCodexSession } from "./receipt.mjs";
test("cached hooks recognize Codex metadata without inferring identity from text", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "receipt-session-"));
  const id = "01a1a8dd-5d17-7003-b08f-40029a7ea7b0";
  const file = path.join(root, "rollout-" + id + ".jsonl");
  try {
    const record = { type: "session_meta", payload: { id, originator: "Codex Desktop", instructions: "x".repeat(20000) } };
    fs.writeFileSync(file, JSON.stringify(record) + "\n");
    assert.equal(isCodexSession(id, root), true);
    record.payload.id = "different";
    fs.writeFileSync(file, JSON.stringify(record) + "\n");
    assert.equal(isCodexSession(id, root), false);
    fs.writeFileSync(file, JSON.stringify({ type: "assistant", payload: { id, originator: "Codex Desktop" } }) + "\n");
    assert.equal(isCodexSession(id, root), false);
    assert.equal(isCodexSession("../invalid", root), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("MCP and unknown tools retain identity without payloads or invented exits", () => {
  const result=fromHookEvent({hook_event_name:"PostToolUse",tool_name:"mcp__cua_repl__js",tool_input:{code:"private code"},tool_response:{content:"private result"}}, {}, "Codex");
  assert.equal(result.actor,"Codex");assert.equal(result.kind,"Change");assert.equal(result.action,"Updated");assert.equal(result.exitCode,null);
  assert.equal(result.tool,"mcp__cua_repl__js");assert.doesNotMatch(JSON.stringify(result),/private code|private result/);
});
test("every label the hook writes is one mac.receipts accepts (Codex and Antigravity receipts were refused 2026-11-13)", () => {
  const KINDS = new Set(["Read", "Change"]), ACTIONS = new Set(["Read", "Created", "Updated", "Deleted"]);
  const events = [
    [{hook_event_name:"PostToolUse",tool_name:"mcp__codex_apps__github__search",tool_input:{},tool_response:{}}, "Codex"],
    [{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"/tmp/x"},tool_response:{}}, "Claude Code"],
    [{toolCall:{name:"view_file",args:{AbsolutePath:"/tmp/x"}},conversationId:"c"}, null],
    [{toolCall:{name:"browser_click",args:{}},conversationId:"c"}, null],
  ];
  for (const [ev, who] of events) {
    const r = fromHookEvent(ev, {}, who);
    if (!r || !r.kind) continue;  // shell/file events are classified later by classify()
    assert.ok(KINDS.has(r.kind), `kind ${r.kind} for ${r.tool}`);
    assert.ok(ACTIONS.has(r.action), `action ${r.action} for ${r.tool}`);
  }
});
