#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

import { IPhoneMirroringDriver } from "./mirror-driver.js";
import { MacOsMirrorControlPort } from "./macos-mirror-port.js";
import { MacOsVisionTextResolver } from "./macos-vision-resolver.js";
import { DeterministicRunner } from "./runner.js";
import type {
  ConfirmationDecision,
  ConfirmationProvider,
  ConfirmationRequest,
  DriverActionResult,
  DriverObservation,
  DriverSession,
  DriverStep,
  ExecutionReceipt,
  PortableDriver
} from "./runtime-types.js";
import { parseCommand, validateReceipt } from "./validator.js";

/**
 * Acceptance-only provider wrapper. After a real approval it stages a reversible screen change
 * before returning to the unchanged runner, placing the live phone deterministically inside the
 * exact interval guarded by CONFIRMATION_STALE.
 */
export class StagedApprovalConfirmationProvider implements ConfirmationProvider {
  constructor(
    private readonly delegate: ConfirmationProvider,
    private readonly stageScreenChange: () => Promise<void>
  ) {}

  async confirm(request: ConfirmationRequest): Promise<ConfirmationDecision> {
    const decision = await this.delegate.confirm(request);
    if (decision.approved) await this.stageScreenChange();
    return decision;
  }
}

class RecordingDriver implements PortableDriver {
  readonly executedStepIds: string[] = [];

  constructor(private readonly delegate: PortableDriver) {}

  startSession(): Promise<DriverSession> {
    return this.delegate.startSession();
  }

  async stopSession(): Promise<void> {
    await this.delegate.stopSession?.();
  }

  observe(): Promise<DriverObservation> {
    return this.delegate.observe();
  }

  async execute(step: DriverStep): Promise<DriverActionResult> {
    this.executedStepIds.push(step.id);
    return this.delegate.execute(step);
  }
}

export interface ConfirmationStaleAcceptanceResult {
  receiptId: string;
  status: "stopped";
  errorCode: "CONFIRMATION_STALE";
  executedStepIds: string[];
  staleStepId: string;
}

/**
 * Live acceptance boundary for the stale-confirmation gate.
 *
 * The existing command first opens General and parks at its confirming About tap. After the
 * acceptance-only provider approves, the wrapper presses Home through the real mirror before
 * the provider resolves. The runner must re-observe that changed screen, stop with
 * CONFIRMATION_STALE, and never deliver the About tap to the driver. The native dialog's own
 * Approve and Deny behavior is deliberately outside this test; both were already proven live.
 */
export async function runConfirmationStaleAcceptance(): Promise<ConfirmationStaleAcceptanceResult> {
  if (process.platform !== "darwin") {
    throw new Error("The CONFIRMATION_STALE live acceptance requires macOS and iPhone Mirroring");
  }

  const source = await readFile(new URL("../fixtures/live/confirmation-stale.json", import.meta.url), "utf8");
  const command = parseCommand(source, "json");
  const port = new MacOsMirrorControlPort();

  try {
    await port.focus();
    const driver = new RecordingDriver(new IPhoneMirroringDriver({
      port,
      resolver: new MacOsVisionTextResolver(),
      actionBounds: await port.getWindowBounds(),
      actions: ["openApp", "tap", "typeText", "swipe", "press"]
    }));
    const confirmationProvider = new StagedApprovalConfirmationProvider(
      {
        async confirm() {
          return { approved: true, actor: "live stale acceptance harness" };
        }
      },
      async () => port.pressKey("super+1")
    );
    const runner = new DeterministicRunner(driver, {
      confirmationProvider,
      idFactory: () => `live-confirmation-stale-${Date.now()}`
    });

    process.stdout.write(
      "CONFIRMATION_STALE live acceptance\n" +
      "The harness will approve its reversible About step, press Home on the real mirror before " +
      "the unchanged runner can act, and require the run to stop as stale.\n"
    );

    const receipt = await runner.run({ command });
    return assertAcceptanceReceipt(receipt, driver.executedStepIds);
  } finally {
    await port.dispose();
  }
}

function assertAcceptanceReceipt(
  receipt: ExecutionReceipt,
  executedStepIds: string[]
): ConfirmationStaleAcceptanceResult {
  validateReceipt(receipt);
  const staleStep = receipt.steps.find((step) => step.id === "open-about");
  const expectedExecuted = [
    "open-settings-general",
    "reset-general-toward-top-1",
    "reset-general-toward-top-2"
  ];
  const executionMatches =
    executedStepIds.length === expectedExecuted.length &&
    executedStepIds.every((stepId, index) => stepId === expectedExecuted[index]);

  if (
    receipt.status !== "stopped" ||
    receipt.error?.code !== "CONFIRMATION_STALE" ||
    staleStep?.status !== "stopped" ||
    staleStep.confirmation?.outcome !== "stale" ||
    staleStep.after !== undefined ||
    staleStep.resolvedTarget !== undefined ||
    !executionMatches
  ) {
    throw new Error(
      "CONFIRMATION_STALE live acceptance failed: " +
      JSON.stringify({
        receiptStatus: receipt.status,
        errorCode: receipt.error?.code,
        staleStepStatus: staleStep?.status,
        confirmationOutcome: staleStep?.confirmation?.outcome,
        committingStepObservedAfter: staleStep?.after !== undefined,
        committingStepResolvedTarget: staleStep?.resolvedTarget !== undefined,
        executedStepIds
      })
    );
  }

  return {
    receiptId: receipt.id,
    status: "stopped",
    errorCode: "CONFIRMATION_STALE",
    executedStepIds: [...executedStepIds],
    staleStepId: staleStep.id
  };
}

const isMain = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  runConfirmationStaleAcceptance().then((result) => {
    process.stdout.write(
      `PASS — ${result.errorCode}; ${result.staleStepId} never reached the driver ` +
      `(executed: ${result.executedStepIds.join(", ")}).\n`
    );
  }).catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
