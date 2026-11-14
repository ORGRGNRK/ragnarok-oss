import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { DirectoryCommandRegistry, InMemoryCommandRegistry, parseCommand } from "../src/index.js";

const command = (version: string) => parseCommand(JSON.stringify({
  schemaVersion: "0.1",
  version,
  id: "test.open-settings",
  name: "Open Settings",
  safety: { risk: "reversible" },
  steps: [{ id: "open", action: "openApp", app: { name: "Settings" } }]
}), "json");

test("command registry selects the newest compatible semantic version", async () => {
  const registry = new InMemoryCommandRegistry([command("1.0.0"), command("1.4.0"), command("2.0.0")]);

  assert.equal((await registry.get("test.open-settings", "^1.0.0"))?.version, "1.4.0");
  assert.equal((await registry.get("test.open-settings", ">=2"))?.version, "2.0.0");
  assert.equal(await registry.get("test.open-settings", "^3.0.0"), undefined);
});

test("directory registry loads versioned JSON and YAML commands recursively", async () => {
  const directory = await mkdtemp(join(tmpdir(), "iphone-command-library-"));
  await writeFile(join(directory, "v1.json"), JSON.stringify(command("1.0.0")));
  await writeFile(join(directory, "v2.yaml"), [
    "schemaVersion: '0.1'",
    "version: 2.0.0",
    "id: test.open-settings",
    "name: Open Settings",
    "safety:",
    "  risk: reversible",
    "steps:",
    "  - id: open",
    "    action: openApp",
    "    app:",
    "      name: Settings",
    ""
  ].join("\n"));

  const registry = new DirectoryCommandRegistry(directory);
  assert.equal((await registry.get("test.open-settings", "1.x"))?.version, "1.0.0");
  assert.equal((await registry.get("test.open-settings"))?.version, "2.0.0");
});
