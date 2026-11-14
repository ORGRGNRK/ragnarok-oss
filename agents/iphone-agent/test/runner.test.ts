import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  DeterministicRunner,
  InMemoryCommandRegistry,
  MemoryReceiptSink,
  parseCommand,
  type DriverActionResult,
  type DriverObservation,
  type DriverSession,
  type DriverStep,
  type PortableDriver
} from "../src/index.js";

const fixture = (path: string): Promise<string> =>
  readFile(new URL(`../fixtures/${path}`, import.meta.url), "utf8");

class FakeDriver implements PortableDriver {
  readonly executed: DriverStep[] = [];
  readonly observations: DriverObservation[] = [];
  executionCount = 0;
  failVerificationAttempts = 0;
  private screenText: string[] = ["Home"];

  constructor(private readonly session: DriverSession) {}

  async startSession(): Promise<DriverSession> {
    return structuredClone(this.session);
  }

  async observe(): Promise<DriverObservation> {
    const observation = {
      capturedAt: new Date().toISOString(),
      screenText: [...this.screenText],
      screenshotRef: `memory://frame-${this.observations.length}`
    };
    this.observations.push(observation);
    return observation;
  }

  async execute(step: DriverStep): Promise<DriverActionResult> {
    this.executed.push(step);
    this.executionCount += 1;
    if (step.action === "openApp") {
      this.screenText = this.executionCount <= this.failVerificationAttempts ? ["Home"] : [step.app.name ?? "App"];
    }
    if (step.action === "tap" && step.target.label === "Send") this.screenText = ["Delivered"];
    return {};
  }
}

const fullSession: DriverSession = {
  id: "fake-mirror",
  version: "test",
  capabilities: {
    actions: ["openApp", "tap", "typeText", "swipe", "press"],
    observations: ["screenshot", "screenText", "target"]
  }
};

test("runs the acceptance command and persists receipts around the action", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  const driver = new FakeDriver(fullSession);
  const sink = new MemoryReceiptSink();
  const runner = new DeterministicRunner(driver, {
    receiptSink: sink,
    idFactory: () => "run-test-success"
  });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "succeeded");
  assert.equal(receipt.steps.length, 1);
  assert.equal(receipt.steps[0]?.verification?.passed, true);
  assert.equal(driver.executed[0]?.action, "openApp");
  assert.ok(sink.snapshots.some((snapshot) => snapshot.steps[0]?.status === "running"));
  assert.equal(sink.snapshots.at(-1)?.status, "succeeded");
});

test("captures a named screenshot artifact without sending a driver action", async () => {
  const command = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    id: "test.capture",
    name: "Capture",
    safety: { risk: "read" },
    steps: [{ id: "capture-top", action: "capture", label: "about-top" }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-capture",
    screenshotArtifactSink: {
      async writeScreenshot(request) {
        assert.equal(request.label, "about-top");
        assert.match(request.observation.screenshotRef ?? "", /^memory:\/\/frame-/);
        return { kind: "screenshot", reference: "/evidence/about-top.png", mediaType: "image/png" };
      }
    }
  });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "succeeded");
  assert.equal(driver.executed.length, 0);
  assert.deepEqual(receipt.artifacts, [
    { kind: "screenshot", reference: "/evidence/about-top.png", mediaType: "image/png" }
  ]);
});

test("retries a verification failure only up to the command bound", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  command.onFailure = { behavior: "retry", maxAttempts: 2 };
  const driver = new FakeDriver(fullSession);
  driver.failVerificationAttempts = 1;
  const runner = new DeterministicRunner(driver, { idFactory: () => "run-test-retry" });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "succeeded");
  assert.equal(driver.executionCount, 2);
  assert.deepEqual(receipt.steps.map((step) => step.status), ["failed", "succeeded"]);
  assert.deepEqual(receipt.steps.map((step) => step.attempt), [1, 2]);
});

test("stops immediately when confirmation is denied", async () => {
  const command = parseCommand(await fixture("confirmation-required/send-message.json"), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-denied",
    confirmationProvider: {
      async confirm() {
        return { approved: false, actor: "tester" };
      }
    }
  });

  const receipt = await runner.run({ command, inputs: { message: "hello" } });

  assert.equal(receipt.status, "stopped");
  assert.equal(receipt.error?.code, "CONFIRMATION_DENIED");
  assert.deepEqual(driver.executed.map((step) => step.id), ["enter-message"]);
  assert.equal(receipt.steps.at(-1)?.confirmation?.outcome, "denied");
});

test("fails before execution when the driver lacks a required capability", async () => {
  const command = parseCommand(await fixture("unsupported/requires-swipe.json"), "json");
  const driver = new FakeDriver({
    id: "limited",
    capabilities: { actions: ["openApp"], observations: ["screenshot"] }
  });
  const runner = new DeterministicRunner(driver, { idFactory: () => "run-test-unsupported" });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "unsupported");
  assert.equal(receipt.error?.code, "UNSUPPORTED_CAPABILITY");
  assert.equal(driver.executed.length, 0);
});

test("checks command preconditions before the first action", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  command.preconditions = [{ screenText: "Settings" }];
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, { idFactory: () => "run-test-precondition" });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "failed");
  assert.equal(receipt.error?.code, "PRECONDITION_FAILED");
  assert.equal(driver.executed.length, 0);
});

test("executes a compatible nested command with namespaced receipts", async () => {
  const child = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.3.0",
    id: "test.child",
    name: "Child",
    safety: { risk: "reversible" },
    steps: [{ id: "open", action: "openApp", app: { name: "Settings" }, expect: { screenText: "Settings" } }]
  }), "json");
  const parent = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.parent",
    name: "Parent",
    safety: { risk: "reversible" },
    steps: [{ id: "invoke", action: "call", commandId: "test.child", commandVersion: "^1.0.0" }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, {
    commandRegistry: new InMemoryCommandRegistry([child]),
    idFactory: () => "run-test-nested"
  });

  const receipt = await runner.run({ command: parent });

  assert.equal(receipt.status, "succeeded");
  assert.deepEqual(receipt.steps.map((step) => step.id), ["invoke", "invoke:open"]);
  assert.deepEqual(receipt.steps.map((step) => step.status), ["succeeded", "succeeded"]);
  assert.deepEqual(driver.executed.map((step) => step.id), ["open"]);
});

test("preflight rejects an unresolved nested command before driver actions", async () => {
  const parent = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    id: "test.parent",
    name: "Parent",
    safety: { risk: "reversible" },
    steps: [{ id: "invoke", action: "call", commandId: "test.missing" }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, { idFactory: () => "run-test-missing" });

  const receipt = await runner.run({ command: parent });

  assert.equal(receipt.status, "unsupported");
  assert.equal(receipt.error?.code, "COMMAND_NOT_FOUND");
  assert.equal(driver.executed.length, 0);
});

test("runs a recovery command and retries the failed step once", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  command.onFailure = { behavior: "recover", recoveryCommandId: "test.go-home" };
  const recovery = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.go-home",
    name: "Go Home",
    safety: { risk: "reversible" },
    steps: [{ id: "home", action: "press", button: "home" }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  driver.failVerificationAttempts = 1;
  const runner = new DeterministicRunner(driver, {
    commandRegistry: new InMemoryCommandRegistry([recovery]),
    idFactory: () => "run-test-recover"
  });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "succeeded");
  assert.deepEqual(driver.executed.map((step) => step.action), ["openApp", "press", "openApp"]);
  assert.ok(receipt.steps.some((step) => step.id === "open-settings:recovery:home" && step.status === "succeeded"));
  assert.deepEqual(receipt.steps.filter((step) => step.id === "open-settings").map((step) => step.attempt), [1, 2]);
});

test("resumes only after completed step boundaries", async () => {
  const command = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.resume",
    name: "Resume",
    safety: { risk: "reversible" },
    steps: [
      { id: "first", action: "openApp", app: { name: "Settings" }, expect: { screenText: "Settings" } },
      { id: "second", action: "openApp", app: { name: "Notes" }, expect: { screenText: "Notes" } }
    ]
  }), "json");

  class ResumeDriver extends FakeDriver {
    failedSecond = false;
    override async execute(step: DriverStep): Promise<DriverActionResult> {
      const result = await super.execute(step);
      if (step.id === "second" && !this.failedSecond) {
        this.failedSecond = true;
        (this as unknown as { screenText: string[] }).screenText = ["Home"];
      }
      return result;
    }
  }

  const driver = new ResumeDriver(fullSession);
  const runner = new DeterministicRunner(driver, { idFactory: () => "run-test-resume" });
  const failed = await runner.run({ command });
  const resumed = await runner.run({ command, resumeFrom: failed });

  assert.equal(failed.status, "failed");
  assert.equal(resumed.status, "succeeded");
  assert.equal(resumed.id, failed.id);
  assert.deepEqual(driver.executed.map((step) => step.id), ["first", "second", "second"]);
  assert.equal(resumed.steps.filter((step) => step.id === "first").length, 1);
  assert.deepEqual(resumed.steps.filter((step) => step.id === "second").map((step) => step.attempt), [1, 2]);
});

test("refuses to resume an external step whose commit outcome is uncertain", async () => {
  const command = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.external-resume",
    name: "External Resume",
    safety: { risk: "external" },
    steps: [{
      id: "send",
      action: "tap",
      target: { label: "Send", fallbackPoint: { x: 0.5, y: 0.5 } },
      expect: { screenText: "Never observed" }
    }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-external-resume",
    confirmationProvider: { async confirm() { return { approved: true }; } }
  });

  const failed = await runner.run({ command });
  const resumed = await runner.run({ command, resumeFrom: failed });

  assert.equal(failed.status, "failed");
  assert.equal(resumed.status, "failed");
  assert.equal(resumed.error?.code, "RESUME_INVALID");
  assert.equal(driver.executed.length, 1);
});

test("does not automatically retry an external step after uncertain verification", async () => {
  const command = parseCommand(JSON.stringify({
    schemaVersion: "0.1",
    version: "1.0.0",
    id: "test.external-retry",
    name: "External Retry",
    onFailure: { behavior: "retry", maxAttempts: 2 },
    safety: { risk: "external" },
    steps: [{
      id: "send",
      action: "tap",
      target: { label: "Send", fallbackPoint: { x: 0.5, y: 0.5 } },
      expect: { screenText: "Never observed" }
    }]
  }), "json");
  const driver = new FakeDriver(fullSession);
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-external-retry",
    confirmationProvider: { async confirm() { return { approved: true }; } }
  });

  const receipt = await runner.run({ command });

  assert.equal(receipt.status, "failed");
  assert.equal(receipt.error?.code, "COMMIT_OUTCOME_UNCERTAIN");
  assert.equal(driver.executed.length, 1);
});
