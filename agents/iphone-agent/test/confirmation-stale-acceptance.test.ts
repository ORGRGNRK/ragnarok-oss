import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { StagedApprovalConfirmationProvider } from "../src/confirmation-stale-acceptance.js";
import {
  dryRunCommand,
  liveCapabilities,
  parseCommand,
  type ConfirmationProvider,
  type ConfirmationRequest
} from "../src/index.js";

const request = {
  command: { id: "test.command", name: "Test command" },
  step: { id: "confirm", action: "confirm", message: "Continue?" },
  risk: "reversible",
  message: "Continue?"
} satisfies ConfirmationRequest;

test("the live stale harness stages a screen change only after approval", async () => {
  const events: string[] = [];
  const delegate: ConfirmationProvider = {
    async confirm() {
      events.push("approved");
      return { approved: true, actor: "tester" };
    }
  };
  const provider = new StagedApprovalConfirmationProvider(delegate, async () => {
    events.push("screen-changed");
  });

  assert.deepEqual(await provider.confirm(request), { approved: true, actor: "tester" });
  assert.deepEqual(events, ["approved", "screen-changed"]);
});

test("the live stale harness does not move the screen after denial", async () => {
  let staged = false;
  const delegate: ConfirmationProvider = {
    async confirm() {
      return { approved: false, actor: "tester" };
    }
  };
  const provider = new StagedApprovalConfirmationProvider(delegate, async () => {
    staged = true;
  });

  assert.deepEqual(await provider.confirm(request), { approved: false, actor: "tester" });
  assert.equal(staged, false);
});

test("the live stale fixture preflights with only its final tap requiring confirmation", async () => {
  const source = await readFile(new URL("../fixtures/live/confirmation-stale.json", import.meta.url), "utf8");
  const command = parseCommand(source, "json");
  const report = await dryRunCommand(command, {}, { capabilities: liveCapabilities });

  assert.equal(report.supported, true);
  assert.equal(report.actionsExecuted, 0);
  assert.deepEqual(report.confirmationPaths, [
    "com.yggdrasil.iphone.accept-confirmation-stale:open-about"
  ]);
});
