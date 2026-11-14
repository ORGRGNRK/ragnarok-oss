import assert from "node:assert/strict";
import test from "node:test";

import { dryRunCommand, InMemoryCommandRegistry, parseCommand } from "../src/index.js";

const parse = (value: Record<string, unknown>) => parseCommand(JSON.stringify(value), "json");
const child = parse({
  schemaVersion: "0.1",
  version: "1.2.0",
  id: "test.send",
  name: "Send",
  inputs: { message: { type: "string" } },
  safety: { risk: "external" },
  steps: [{ id: "enter", action: "typeText", text: "${input.message}" }]
});
const parent = parse({
  schemaVersion: "0.1",
  version: "1.0.0",
  id: "test.parent",
  name: "Parent",
  safety: { risk: "reversible" },
  steps: [{ id: "invoke", action: "call", commandId: "test.send", commandVersion: "^1.0.0", inputs: { message: "hello" } }]
});

test("dry run expands nested commands, confirmation paths, and capabilities without actions", async () => {
  const report = await dryRunCommand(parent, {}, {
    capabilities: { actions: ["typeText"], observations: [] },
    registry: new InMemoryCommandRegistry([child])
  });

  assert.equal(report.supported, true);
  assert.equal(report.actionsExecuted, 0);
  assert.deepEqual(report.steps.map((step) => step.path), ["test.parent:invoke", "test.parent:invoke:enter"]);
  assert.deepEqual(report.requiredCapabilities.actions, ["typeText"]);
  assert.deepEqual(report.confirmationPaths, ["test.parent:invoke:enter"]);
});

test("dry run reports missing nested capabilities before execution", async () => {
  const report = await dryRunCommand(parent, {}, {
    capabilities: { actions: [], observations: [] },
    registry: new InMemoryCommandRegistry([child])
  });

  assert.equal(report.supported, false);
  assert.equal(report.actionsExecuted, 0);
  assert.deepEqual(report.missingCapabilities, [{ kind: "action", capability: "typeText", stepIds: ["test.parent:invoke:enter"] }]);
});

test("dry run detects recursive command calls", async () => {
  const recursive = parse({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.recursive",
    name: "Recursive",
    safety: { risk: "reversible" },
    steps: [{ id: "again", action: "call", commandId: "test.recursive" }]
  });
  const report = await dryRunCommand(recursive, {}, {
    capabilities: { actions: [], observations: [] },
    registry: new InMemoryCommandRegistry([recursive])
  });

  assert.equal(report.supported, false);
  assert.equal(report.errors[0]?.code, "COMMAND_CYCLE");
});
