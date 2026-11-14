import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { parseCommand } from "../src/index.js";

const execFileAsync = promisify(execFile);
const cliPath = new URL("../dist/cli.js", import.meta.url).pathname;
const fixturePath = new URL("../fixtures/valid/open-settings.json", import.meta.url).pathname;

test("CLI validates a command file", async () => {
  const result = await execFileAsync(process.execPath, [cliPath, "validate", fixturePath]);
  assert.match(result.stdout, /Valid command: com\.yggdrasil\.iphone\.open-settings/);
});

test("CLI authors a validated command from a safe text pattern", async () => {
  const result = await execFileAsync(process.execPath, [cliPath, "from-text", "open Settings"]);
  const command = parseCommand(result.stdout, "json");

  assert.equal(command.steps[0]?.action, "openApp");
  assert.equal(command.safety.risk, "reversible");
});

test("CLI converts canonical JSON to YAML on stdout", async () => {
  const result = await execFileAsync(process.execPath, [cliPath, "convert", fixturePath, "--to", "yaml"]);
  const command = parseCommand(result.stdout, "yaml");

  assert.equal(command.id, "com.yggdrasil.iphone.open-settings");
  assert.deepEqual(command.onFailure, { behavior: "stop" });
});

test("CLI dry-run emits a no-action capability report", async () => {
  const directory = await mkdtemp(join(tmpdir(), "iphone-cli-dry-run-"));
  const capabilitiesPath = join(directory, "capabilities.json");
  await writeFile(capabilitiesPath, JSON.stringify({
    actions: ["openApp"],
    observations: ["screenText"]
  }));

  const result = await execFileAsync(process.execPath, [
    cliPath,
    "dry-run",
    fixturePath,
    "--capabilities",
    capabilitiesPath
  ]);
  const report = JSON.parse(result.stdout) as { supported: boolean; actionsExecuted: number };

  assert.equal(report.supported, true);
  assert.equal(report.actionsExecuted, 0);
});
