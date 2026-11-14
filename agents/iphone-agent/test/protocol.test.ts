import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  CommandProtocolError,
  assessSafety,
  assertCapabilities,
  checkCapabilities,
  getCommandSchema,
  getReceiptSchema,
  parseCommand,
  prepareCommand,
  requiredCapabilities,
  validateReceipt,
  type DriverCapabilities
} from "../src/index.js";

const fixtureUrl = (path: string): URL => new URL(`../fixtures/${path}`, import.meta.url);
const fixture = (path: string): Promise<string> => readFile(fixtureUrl(path), "utf8");

const mirrorCapabilities: DriverCapabilities = {
  actions: ["openApp", "tap", "typeText", "swipe", "press"],
  observations: ["screenshot", "screenText", "app", "target"]
};

test("publishes Draft 2020-12 command and receipt schemas", () => {
  assert.equal((getCommandSchema() as { $schema: string }).$schema, "https://json-schema.org/draft/2020-12/schema");
  assert.equal((getReceiptSchema() as { $schema: string }).$schema, "https://json-schema.org/draft/2020-12/schema");
});

test("parses and normalizes the first acceptance command", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");

  assert.equal(command.id, "com.yggdrasil.iphone.open-settings");
  assert.equal(command.version, "1.0.0");
  assert.deepEqual(command.inputs, {});
  assert.deepEqual(command.preconditions, []);
  assert.deepEqual(command.onFailure, { behavior: "stop" });
  assert.equal(command.safety.requiresConfirmation, false);
});

test("rejects invalid command versions and call version ranges", () => {
  const base = {
    schemaVersion: "0.1",
    version: "not-semver",
    id: "test.version",
    name: "Version",
    safety: { risk: "reversible" },
    steps: [{ id: "open", action: "openApp", app: { name: "Settings" } }]
  };
  assert.throws(
    () => parseCommand(JSON.stringify(base), "json"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );

  base.version = "1.0.0";
  base.steps = [{ id: "call", action: "call", commandId: "test.child", commandVersion: "definitely not a range" } as never];
  assert.throws(
    () => parseCommand(JSON.stringify(base), "json"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );
});

test("accepts YAML and resolves typed runtime inputs", async () => {
  const command = parseCommand(await fixture("valid/search-settings.yaml"), "yaml");
  const prepared = prepareCommand(command, { query: "General" });

  assert.equal(prepared.inputs.query, "General");
  assert.equal(prepared.inputs.auditTag, "slice-2");
  assert.equal(prepared.command.steps[1]?.action, "typeText");
  if (prepared.command.steps[1]?.action === "typeText") {
    assert.equal(prepared.command.steps[1].text, "General");
  }
  assert.deepEqual(prepared.command.postconditions, [{ screenText: "General" }]);
});

test("rejects structurally invalid commands with a machine-readable error", async () => {
  assert.throws(
    () => parseCommand(awaitableValue, "json"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "PARSE_ERROR"
  );

  const source = await fixture("invalid/missing-step-id.json");
  assert.throws(
    () => parseCommand(source, "json"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );
});

test("rejects missing, unknown, and incorrectly typed inputs", async () => {
  const command = parseCommand(await fixture("valid/search-settings.yaml"), "yaml");

  assert.throws(
    () => prepareCommand(command),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "INPUT_MISSING"
  );
  assert.throws(
    () => prepareCommand(command, { query: 42 }),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "INPUT_TYPE"
  );
  assert.throws(
    () => prepareCommand(command, { query: "General", extra: true }),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "INPUT_UNKNOWN"
  );
});

test("redacts secret inputs while preserving their resolved value for execution", () => {
  const command = parseCommand(`{
    "schemaVersion":"0.1",
    "id":"com.example.secret",
    "name":"Secret input",
    "inputs":{"value":{"type":"string","secret":true}},
    "safety":{"risk":"credential"},
    "steps":[{"id":"type","action":"typeText","text":"${"${input.value}"}","safety":{"risk":"credential"}}]
  }`, "json");

  const prepared = prepareCommand(command, { value: "not-for-the-receipt" });
  assert.equal(prepared.inputs.value, "not-for-the-receipt");
  assert.equal(prepared.redactedInputs.value, "[REDACTED]");
});

test("collects portable action and observation requirements", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  assert.deepEqual(requiredCapabilities(command), {
    actions: ["openApp"],
    observations: ["screenText"]
  });
  assert.equal(checkCapabilities(command, mirrorCapabilities).supported, true);
});

test("a capture step is portable read-only evidence that requires screenshots", () => {
  const command = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    id: "test.capture",
    name: "Capture",
    safety: { risk: "read" },
    steps: [{ id: "top", action: "capture", label: "about-top" }]
  }), "json");

  assert.deepEqual(requiredCapabilities(command), { actions: [], observations: ["screenshot"] });
  assert.equal(assessSafety(command).steps[0]?.risk, "read");
  assert.equal(checkCapabilities(command, { actions: [], observations: [] }).supported, false);
});

test("reports unsupported capabilities before execution", async () => {
  const command = parseCommand(await fixture("unsupported/requires-swipe.json"), "json");
  const withoutSwipe: DriverCapabilities = {
    actions: ["openApp", "tap", "typeText", "press"],
    observations: ["screenshot"]
  };
  const result = checkCapabilities(command, withoutSwipe);

  assert.equal(result.supported, false);
  assert.deepEqual(result.missing, [{ kind: "action", capability: "swipe", stepIds: ["next-page"] }]);
  assert.throws(
    () => assertCapabilities(command, withoutSwipe),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "UNSUPPORTED_CAPABILITY"
  );
});

test("requires confirmation for the committing external step", async () => {
  const command = parseCommand(await fixture("confirmation-required/send-message.json"), "json");
  const assessment = assessSafety(command);

  assert.equal(assessment.risk, "external");
  assert.equal(assessment.requiresConfirmation, true);
  assert.deepEqual(assessment.confirmationStepIds, ["send-message"]);
});

test("validates a successful receipt and rejects an incomplete terminal receipt", () => {
  const receipt = {
    schemaVersion: "0.1",
    id: "run-20260819-001",
    command: { id: "com.yggdrasil.iphone.open-settings", schemaVersion: "0.1" },
    status: "succeeded",
    startedAt: "2026-08-19T16:40:00.000Z",
    endedAt: "2026-08-19T16:40:02.000Z",
    inputs: {},
    driver: {
      id: "iphone-mirroring",
      version: "0.1",
      actions: ["openApp", "tap", "typeText", "swipe", "press"],
      observations: ["screenshot", "screenText", "target"]
    },
    steps: [
      {
        id: "open-settings",
        action: "openApp",
        status: "succeeded",
        startedAt: "2026-08-19T16:40:00.000Z",
        endedAt: "2026-08-19T16:40:02.000Z",
        verification: { passed: true, message: "Observed Settings" }
      }
    ]
  };

  assert.doesNotThrow(() => validateReceipt(receipt));
  const incomplete = structuredClone(receipt) as Record<string, unknown>;
  delete incomplete.endedAt;
  assert.throws(
    () => validateReceipt(incomplete),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );
});

const awaitableValue = "not json";
