// node --test hooks/mac-receipts/classify.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { classify } from "./classify.mjs";

const c = (cmd) => { const r = classify(cmd, "/w"); return `${r.kind}/${r.action}${r.target ? " " + r.target : ""}`; };
test("read-only commands are Read", () => {
  for (const cmd of ["ls -la /tmp | head -3", "grep -q x /etc/hosts", "export PATH=$PATH:/x; cd ~/y && git status",
    "git -C /tmp log --oneline -3", "echo 'rm -rf /'", "curl -s https://x/y", "docker ps", "cat a | sort | uniq -c"])
    assert.equal(c(cmd), "Read/Read", cmd);
});
test("changes carry action and clean target", () => {
  assert.equal(c("touch /tmp/a"), "Change/Created /tmp/a");
  assert.equal(c("rm /tmp/a"), "Change/Deleted /tmp/a");
  assert.equal(c("mkdir x"), "Change/Created /w/x");
  assert.equal(c("echo hi > out.txt"), "Change/Updated /w/out.txt");
  assert.equal(c("sed -i s/a/b/ f.txt"), "Change/Updated /w/f.txt");
  assert.equal(c("chmod 600 /etc/x"), "Change/Updated /etc/x");
  assert.equal(c("node build.js"), "Change/Updated");
  assert.equal(c("ls; rm -rf /tmp/zz"), "Change/Deleted /tmp/zz");
  assert.equal(c("curl -X POST https://api/x -d a=1"), "Change/Updated https://api/x");
});
test("2>&1 and friends are not a separate command (2026-11-15: every `... 2>&1` was logged as a change)", () => {
  for (const cmd of ["ls -a .mcp.json 2>&1", "git status 2>&1 | head", "ls x >&2", "tail -3 ~/.ragnarok/receipts.log 2>&1"])
    assert.equal(c(cmd), "Read/Read", cmd);
  assert.equal(c("rm /tmp/a 2>&1"), "Change/Deleted /tmp/a");
});
test("NAME=\"quoted\" prefix does not hide the program", () => {
  assert.equal(c('MEMORY_ACTOR="claude" ragnarok-memory remember k "t" "f"'), "Change/Updated");
  assert.equal(c('FOO="x" rm /tmp/a'), "Change/Deleted /tmp/a");
  assert.equal(c('FOO="x" ls'), "Read/Read");
});
test("read-only subcommands of Ragnarok tools, claude and gh", () => {
  for (const cmd of ['ragnarok-memory search "zoho"', "ragnarok-memory get k", "scripts/log-change tail 5",
    "timeout 60 claude mcp list", "gh pr view 3", "gh auth status"])
    assert.equal(c(cmd), "Read/Read", cmd);
  for (const cmd of ["claude mcp add x y", "gh pr create", "scripts/log-change --cmd x"])
    assert.equal(c(cmd).split(" ")[0], "Change/Updated", cmd);
});
test("ssh host 'cmd' is judged by the remote command", () => {
  assert.equal(c(`timeout 8 ssh -o BatchMode=yes alexus 'docker ps --format "{{.Names}}" | sort' 2>&1`), "Read/Read");
  assert.equal(c(`ssh alexus "whoami; docker ps"`), "Read/Read");
  assert.equal(c(`ssh alexus 'rm -rf /tmp/x'`).startsWith("Change/Deleted"), true);
  assert.equal(c(`ssh -o BatchMode=yes alexus "docker exec pg psql -c \\"select 1\\""`).startsWith("Change"), true);
  assert.equal(c("ssh alexus"), "Change/Updated"); // interactive: unknown, stays a change
});
test("curl -o /dev/null is a read; URL target has no trailing punctuation", () => {
  assert.equal(c("curl -s -o /dev/null -w '%{http_code}' https://mcp-server.example.com/mcp; ls"), "Read/Read");
  assert.equal(c("curl -o out.html https://x.y/z; ls"), "Change/Updated https://x.y/z");
});
test("heredoc body is data, not commands", () => {
  assert.equal(c("cat >> t.mjs <<'EOF'\nrm /tmp/x\nEOF"), "Change/Updated /w/t.mjs");
  assert.equal(c("cat <<EOF | wc -l\nrm -rf /\nEOF"), "Read/Read");
  assert.equal(c("python3 - <<'PY'\nprint(1)\nPY\nrm /tmp/a"), "Change/Deleted /tmp/a");
});
