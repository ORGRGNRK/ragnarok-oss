import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  CommandProtocolError,
  DeterministicRunner,
  LauncherService,
  bindScreen,
  compareBinding,
  createDemoDriver,
  liveCapabilities,
  parseCommand,
  validateReceipt,
  type CommandDocument,
  type ConfirmationProvider,
  type DriverActionResult,
  type DriverObservation,
  type DriverSession,
  type DriverStep,
  type PortableDriver
} from "../src/index.js";

const fixture = (path: string): Promise<string> =>
  readFile(new URL(`../fixtures/${path}`, import.meta.url), "utf8");

interface Line {
  text: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Vision reports a bottom-left origin, so a status bar line sits near y = 1. */
const statusBar = (text: string): Line => ({ text, x: 0.05, y: 0.965, width: 0.1, height: 0.02 });
/** Measured from a live 381x824 mirror window: the status bar renders at 0.0710 from the top. */
const measuredStatusBar = (text: string): Line => ({ text, x: 0.05, y: 0.919, width: 0.1, height: 0.02 });
const row = (text: string, y: number): Line => ({ text, x: 0.2, y, width: 0.3, height: 0.03 });

function screen(lines: Line[]): DriverObservation {
  return {
    capturedAt: "2026-08-20T12:00:00.000Z",
    screenText: lines.map((line) => line.text),
    metadata: { recognizedText: lines.map((line) => ({ ...line, confidence: 0.9 })) }
  };
}

const composer = [statusBar("9:41"), row("To: Alex", 0.8), row("Send", 0.5)];

test("a still screen stays still while the clock and battery move", () => {
  const approved = bindScreen(screen(composer));
  const later = bindScreen(screen([statusBar("9:42"), row("To: Alex", 0.8), row("Send", 0.5)]));

  assert.equal(approved.positioned, true);
  assert.deepEqual(compareBinding(approved, later), { stable: true });
});

test("the status bar band covers where a real mirror window puts it", () => {
  // Carrier and battery text is not clock-shaped, so only the band can absorb it. A band sized
  // for the phone's own status bar rather than the captured window would sit above this line.
  const approved = bindScreen(screen([measuredStatusBar("SOS"), row("About", 0.5)]));
  const later = bindScreen(screen([measuredStatusBar("5G"), row("About", 0.5)]));

  assert.deepEqual(compareBinding(approved, later), { stable: true });
  assert.deepEqual(approved.entries, ["about@22,31"]);
});

test("a clock reading is ignored even outside the status bar", () => {
  const approved = bindScreen(screen([row("Sent 9:41 AM", 0.7), row("9:41", 0.6), row("Send", 0.5)]));
  const later = bindScreen(screen([row("Sent 9:41 AM", 0.7), row("9:44", 0.6), row("Send", 0.5)]));

  assert.deepEqual(compareBinding(approved, later), { stable: true });
});

test("content that actually changed voids the binding", () => {
  const approved = bindScreen(screen(composer));
  const later = bindScreen(screen([statusBar("9:41"), row("To: Sam", 0.8), row("Send", 0.5)]));

  const comparison = compareBinding(approved, later);
  assert.equal(comparison.stable, false);
  assert.match(comparison.reason ?? "", /1 item left or moved and 1 appeared/);
});

test("a row that moved without changing its text voids the binding", () => {
  const approved = bindScreen(screen(composer));
  const later = bindScreen(screen([statusBar("9:41"), row("To: Alex", 0.8), row("Send", 0.25)]));

  assert.equal(compareBinding(approved, later).stable, false);
});

test("a different foreground app voids the binding", () => {
  const base = screen(composer);
  const approved = bindScreen({ ...base, app: { name: "Messages" } });
  const later = bindScreen({ ...base, app: { name: "Mail" } });

  assert.deepEqual(compareBinding(approved, later), {
    stable: false,
    reason: "a different app is in the foreground"
  });
});

test("a driver without bounding boxes still binds on text alone", () => {
  const approved = bindScreen({ capturedAt: "2026-08-20T12:00:00.000Z", screenText: ["9:41", "Send"] });
  const later = bindScreen({ capturedAt: "2026-08-20T12:01:00.000Z", screenText: ["9:42", "Send"] });

  assert.equal(approved.positioned, false);
  assert.deepEqual(compareBinding(approved, later), { stable: true });
  assert.equal(
    compareBinding(approved, bindScreen({ capturedAt: "2026-08-20T12:01:00.000Z", screenText: ["Send", "Undo"] })).stable,
    false
  );
});

/** A driver whose screen the test can move underneath the runner, exactly as a phone would. */
class ScreenDriver implements PortableDriver {
  readonly executed: DriverStep[] = [];
  lines: Line[] = [...composer];

  async startSession(): Promise<DriverSession> {
    return {
      id: "screen-fake",
      version: "test",
      capabilities: {
        actions: ["openApp", "tap", "typeText", "swipe", "press"],
        observations: ["screenshot", "screenText", "target"]
      }
    };
  }

  async observe(): Promise<DriverObservation> {
    return screen(this.lines);
  }

  async execute(step: DriverStep): Promise<DriverActionResult> {
    this.executed.push(step);
    if (step.action === "tap" && step.target.label === "Send") {
      this.lines = [statusBar("9:41"), row("Delivered", 0.5)];
    }
    return {};
  }
}

const denier: ConfirmationProvider = {
  async confirm() {
    return { approved: false, actor: "tester" };
  }
};

const approver = (onAsk?: () => void): ConfirmationProvider => ({
  async confirm() {
    onAsk?.();
    return { approved: true, actor: "tester" };
  }
});

test("an approval records the sentence and the screen it was given for", async () => {
  const command = parseCommand(await fixture("confirmation-required/send-message.json"), "json");
  const driver = new ScreenDriver();
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-approved",
    confirmationProvider: approver()
  });

  const receipt = await runner.run({ command, inputs: { message: "hello" } });

  assert.equal(receipt.status, "succeeded");
  assert.deepEqual(driver.executed.map((step) => step.id), ["enter-message", "send-message"]);

  const confirmation = receipt.steps.at(-1)?.confirmation;
  assert.equal(confirmation?.outcome, "approved");
  assert.equal(confirmation?.actor, "tester");
  assert.equal(confirmation?.shown?.risk, "external");
  assert.equal(confirmation?.shown?.message, "Tap “Send”, then check that the screen shows “Delivered”");
  assert.deepEqual(confirmation?.shown?.screen?.screenText, ["9:41", "To: Alex", "Send"]);
  validateReceipt(receipt);
});

test("an approval is void if the screen changes before the action runs", async () => {
  const command = parseCommand(await fixture("confirmation-required/send-message.json"), "json");
  const driver = new ScreenDriver();
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-stale",
    // The phone moves on while the dialog is open — the classic reason an approval must not be spendable.
    confirmationProvider: approver(() => {
      driver.lines = [statusBar("9:41"), row("To: Alex", 0.8), row("Delete", 0.5)];
    })
  });

  const receipt = await runner.run({ command, inputs: { message: "hello" } });

  assert.equal(receipt.status, "stopped");
  assert.equal(receipt.error?.code, "CONFIRMATION_STALE");
  assert.deepEqual(driver.executed.map((step) => step.id), ["enter-message"]);
  assert.equal(receipt.steps.at(-1)?.confirmation?.outcome, "stale");
  assert.equal(receipt.steps.at(-1)?.status, "stopped");
  assert.equal(receipt.steps.at(-1)?.confirmation?.shown?.risk, "external");
  validateReceipt(receipt);
});

/** The same shape as the send-message fixture, with the message inline so no input is needed. */
test("a denial keeps the sentence and the actor, not just the verdict", async () => {
  const command = parseCommand(await fixture("confirmation-required/send-message.json"), "json");
  const driver = new ScreenDriver();
  const runner = new DeterministicRunner(driver, {
    idFactory: () => "run-test-denied-record",
    confirmationProvider: denier
  });

  const receipt = await runner.run({ command, inputs: { message: "hello" } });
  const step = receipt.steps.at(-1);

  assert.equal(receipt.status, "stopped");
  assert.equal(step?.status, "stopped");
  assert.deepEqual(driver.executed.map((executed) => executed.id), ["enter-message"]);
  assert.equal(step?.confirmation?.outcome, "denied");
  assert.equal(step?.confirmation?.actor, "tester");
  assert.equal(step?.confirmation?.shown?.message, "Tap “Send”, then check that the screen shows “Delivered”");
  assert.equal(step?.confirmation?.shown?.screen?.screenText?.includes("Send"), true);
  validateReceipt(receipt);
});

async function externalCommand(risk = "external"): Promise<CommandDocument> {
  const document = JSON.parse(await fixture("confirmation-required/send-message.json")) as Record<string, unknown>;
  document.safety = { risk };
  delete document.inputs;
  const steps = document.steps as Array<Record<string, unknown>>;
  steps[0]!.text = "hello";
  return parseCommand(JSON.stringify(document), "json");
}

function launcher(command: CommandDocument, confirmationProvider?: ConfirmationProvider): LauncherService {
  return new LauncherService({
    commands: [command],
    driverFactory: async () => createDemoDriver(),
    mode: "demo",
    capabilities: liveCapabilities,
    ...(confirmationProvider ? { confirmationProvider } : {})
  });
}

test("without a confirmation provider the launcher still refuses a committing command", async () => {
  const service = launcher(await externalCommand());

  assert.equal(service.status().commands[0]?.enabled, false);
  await assert.rejects(
    () => service.dryRun("com.yggdrasil.iphone.send-message"),
    (error: CommandProtocolError) => error.code === "CONFIRMATION_UNAVAILABLE"
  );
});

test("a confirmation provider unlocks external commands and nothing above them", async () => {
  const service = launcher(await externalCommand(), approver());
  assert.equal(service.status().commands[0]?.enabled, true);
  const preflight = await service.dryRun("com.yggdrasil.iphone.send-message");
  assert.deepEqual(preflight.confirmationPaths, ["com.yggdrasil.iphone.send-message:send-message"]);

  for (const risk of ["financial", "destructive", "credential"]) {
    const blocked = launcher(await externalCommand(risk), approver());
    const card = blocked.status().commands[0];
    assert.equal(card?.enabled, false, `${risk} must stay blocked`);
    assert.match(card?.unavailableReason ?? "", /move money, destroy data, or use credentials/);
    await assert.rejects(
      () => blocked.dryRun("com.yggdrasil.iphone.send-message"),
      (error: CommandProtocolError) => error.code === "CONFIRMATION_UNAVAILABLE"
    );
  }
});
