import { assertCommandVersion } from "./catalog.js";
import { evaluateCondition } from "./conditions.js";
import { dryRunCommand } from "./dry-run.js";
import { describeStep } from "./describe.js";
import { CommandProtocolError } from "./errors.js";
import { prepareCommand } from "./inputs.js";
import { assessSafety } from "./policy.js";
import { bindScreen, compareBinding } from "./screen-binding.js";
import type {
  ConfirmationShown,
  DriverActionResult,
  DriverObservation,
  DriverSession,
  ExecutionReceipt,
  PortableDriver,
  ReceiptError,
  RunRequest,
  RunnerOptions,
  StepReceipt
} from "./runtime-types.js";
import type {
  CommandDocument,
  CommandStep,
  FailureBehavior,
  RiskClass,
  StepSafetyAssessment
} from "./types.js";
import { validateReceipt } from "./validator.js";

const driverActionNames = new Set<CommandStep["action"]>(["openApp", "tap", "typeText", "swipe", "press"]);
const riskRank: Record<RiskClass, number> = {
  read: 0,
  reversible: 1,
  external: 2,
  financial: 3,
  destructive: 4,
  credential: 5
};

export class DeterministicRunner {
  private readonly clock: () => Date;
  private readonly idFactory: () => string;
  private readonly waitIntervalMs: number;

  constructor(private readonly driver: PortableDriver, private readonly options: RunnerOptions = {}) {
    this.clock = options.clock ?? (() => new Date());
    this.idFactory = options.idFactory ?? (() => `run-${Date.now()}`);
    this.waitIntervalMs = options.waitIntervalMs ?? 100;
  }

  async run(request: RunRequest): Promise<ExecutionReceipt> {
    const prepared = prepareCommand(request.command, request.inputs);
    const startedAt = this.now();
    let session: DriverSession;

    try {
      session = await this.driver.startSession();
    } catch (error) {
      const terminal = this.terminalReceipt(
        prepared.redactedInputs,
        prepared.command,
        startedAt,
        "failed",
        { id: "unavailable", actions: [], observations: [] },
        protocolError(error, "DRIVER_ERROR")
      );
      await this.persist(terminal);
      return terminal;
    }

    let receipt: ExecutionReceipt;
    try {
      receipt = this.initializeReceipt(prepared.command, prepared.redactedInputs, session, request.resumeFrom);
    } catch (error) {
      const terminal = this.terminalReceipt(
        prepared.redactedInputs,
        prepared.command,
        startedAt,
        "failed",
        receiptDriver(session),
        protocolError(error, "RESUME_INVALID")
      );
      await this.persist(terminal);
      await this.stopSession();
      return terminal;
    }

    try {
      const preflight = await dryRunCommand(prepared.command, prepared.inputs, {
        capabilities: session.capabilities,
        ...(this.options.commandRegistry ? { registry: this.options.commandRegistry } : {}),
        ...(this.options.machineSafetyFloor ? { machineSafetyFloor: this.options.machineSafetyFloor } : {})
      });
      if (!preflight.supported) {
        const firstError = preflight.errors[0];
        const error = firstError
          ? new CommandProtocolError(firstError.code, firstError.message, {
              ...(firstError.path ? { path: firstError.path } : {}),
              details: preflight
            })
          : new CommandProtocolError("UNSUPPORTED_CAPABILITY", "Driver lacks required capabilities", {
              details: preflight
            });
        receipt.status = "unsupported";
        receipt.endedAt = this.now();
        receipt.error = protocolError(error, "UNSUPPORTED_CAPABILITY");
        await this.persist(receipt);
        return receipt;
      }

      await this.persist(receipt);
      await this.runCommandSteps(prepared.command, prepared.inputs, receipt, "", []);

      receipt.status = "succeeded";
      receipt.endedAt = this.now();
      delete receipt.error;
      await this.persist(receipt);
      return receipt;
    } catch (error) {
      const receiptError = protocolError(error, "DRIVER_ERROR");
      receipt.status = terminalStatus(receiptError, prepared.command.onFailure.behavior);
      receipt.endedAt = this.now();
      receipt.error = receiptError;
      await this.persist(receipt);
      return receipt;
    } finally {
      await this.stopSession();
    }
  }

  private async runCommandSteps(
    command: CommandDocument,
    inputs: Record<string, unknown>,
    receipt: ExecutionReceipt,
    prefix: string,
    stack: string[]
  ): Promise<void> {
    const prepared = prepareCommand(command, inputs);
    const stackKey = `${prepared.command.id}@${prepared.command.version}`;
    if (stack.includes(stackKey)) {
      throw new CommandProtocolError("COMMAND_CYCLE", `Command cycle detected: ${[...stack, stackKey].join(" -> ")}`);
    }

    if (!hasCompletedInScope(receipt, prefix)) {
      const initialObservation = await this.driver.observe();
      for (const condition of prepared.command.preconditions) {
        const verification = evaluateCondition(condition, initialObservation);
        if (!verification.passed) {
          throw new CommandProtocolError(
            "PRECONDITION_FAILED",
            `Command ${prepared.command.id} precondition failed: ${verification.message ?? "condition did not match"}`
          );
        }
      }
    }

    const safety = assessSafety(prepared.command, this.options.machineSafetyFloor);
    for (const step of prepared.command.steps) {
      const receiptId = prefix ? `${prefix}:${step.id}` : step.id;
      if (hasSucceeded(receipt, receiptId)) continue;

      const stepSafety = safety.steps.find((assessment) => assessment.stepId === step.id);
      this.assertResumeSafe(receipt, receiptId, stepSafety);
      try {
        await this.runStep(
          prepared.command,
          step,
          stepSafety,
          prepared.command.onFailure,
          receipt,
          receiptId,
          [...stack, stackKey]
        );
      } catch (error) {
        if (prepared.command.onFailure.behavior !== "recover") throw error;
        this.assertRepeatSafe(receipt, receiptId, stepSafety);
        await this.runRecovery(prepared.command, step, stepSafety, receipt, receiptId, [...stack, stackKey]);
        await this.runStep(
          prepared.command,
          step,
          stepSafety,
          { behavior: "stop" },
          receipt,
          receiptId,
          [...stack, stackKey]
        );
      }
    }

    const finalObservation = await this.driver.observe();
    for (const condition of prepared.command.postconditions) {
      const verification = evaluateCondition(condition, finalObservation);
      if (!verification.passed) {
        throw new CommandProtocolError(
          "POSTCONDITION_FAILED",
          `Command ${prepared.command.id} postcondition failed: ${verification.message ?? "condition did not match"}`
        );
      }
    }
  }

  private async runStep(
    command: CommandDocument,
    step: CommandStep,
    safety: StepSafetyAssessment | undefined,
    failureBehavior: FailureBehavior,
    receipt: ExecutionReceipt,
    receiptId: string,
    stack: string[]
  ): Promise<void> {
    const attemptBudget = failureBehavior.behavior === "retry" ? (failureBehavior.maxAttempts ?? 1) : 1;
    const firstAttempt = nextAttempt(receipt, receiptId);
    const finalAttempt = firstAttempt + attemptBudget - 1;

    let lastError: unknown;
    for (let attempt = firstAttempt; attempt <= finalAttempt; attempt += 1) {
      const stepReceipt: StepReceipt = {
        id: receiptId,
        action: step.action,
        status: "running",
        attempt,
        startedAt: this.now()
      };
      receipt.steps.push(stepReceipt);
      await this.persist(receipt);

      try {
        const before = await this.driver.observe();
        stepReceipt.before = before;
        if (step.precondition) {
          const verification = evaluateCondition(step.precondition, before);
          if (!verification.passed) {
            throw new CommandProtocolError(
              "PRECONDITION_FAILED",
              `Step ${receiptId} precondition failed: ${verification.message ?? "condition did not match"}`
            );
          }
        }

        await this.confirmIfRequired(command.id, command.name, step, safety, before, stepReceipt);
        const result = await this.executeStep(step, stepReceipt.before, receipt, receiptId, stack);
        stepReceipt.after = result.observation ?? (await this.driver.observe());
        if (result.action.resolvedTarget) stepReceipt.resolvedTarget = result.action.resolvedTarget;

        const verification = this.verifyStep(step, stepReceipt.after);
        stepReceipt.verification = verification;
        if (!verification.passed) {
          throw new CommandProtocolError(
            "POSTCONDITION_FAILED",
            `Step ${receiptId} verification failed: ${verification.message ?? "condition did not match"}`
          );
        }

        stepReceipt.status = "succeeded";
        stepReceipt.endedAt = this.now();
        await this.persist(receipt);
        return;
      } catch (error) {
        lastError = error;
        this.recordStepFailure(stepReceipt, error);
        await this.persist(receipt);
        if (attempt < finalAttempt) this.assertRepeatSafe(receipt, receiptId, safety);
      }
    }

    throw lastError;
  }

  private async executeStep(
    step: CommandStep,
    before: DriverObservation,
    receipt: ExecutionReceipt,
    receiptId: string,
    stack: string[]
  ): Promise<{ action: DriverActionResult; observation?: DriverObservation }> {
    if (driverActionNames.has(step.action)) {
      return { action: await this.driver.execute(step as Parameters<PortableDriver["execute"]>[0]) };
    }
    if (step.action === "assert") {
      const verification = evaluateCondition(step.condition, before);
      if (!verification.passed) {
        throw new CommandProtocolError("POSTCONDITION_FAILED", verification.message ?? "Assertion failed");
      }
      return { action: {}, observation: before };
    }
    if (step.action === "waitFor") {
      const observation = await this.waitFor(step.condition, step.timeoutMs ?? 10_000);
      return { action: {}, observation };
    }
    if (step.action === "confirm") return { action: {}, observation: before };
    if (step.action === "capture") {
      if (!before.screenshotRef) {
        throw new CommandProtocolError(
          "DRIVER_ERROR",
          `Step ${receiptId} could not capture evidence because the observation had no screenshot`
        );
      }
      const artifact = this.options.screenshotArtifactSink
        ? await this.options.screenshotArtifactSink.writeScreenshot({
            receiptId: receipt.id,
            stepId: receiptId,
            label: step.label,
            observation: before
          })
        : { kind: "screenshot" as const, reference: before.screenshotRef, mediaType: "image/png" };
      receipt.artifacts ??= [];
      const existing = receipt.artifacts.findIndex((candidate) => candidate.reference === artifact.reference);
      if (existing === -1) receipt.artifacts.push(artifact);
      else receipt.artifacts[existing] = artifact;
      return { action: {}, observation: before };
    }
    if (step.action === "call") {
      if (!this.options.commandRegistry) {
        throw new CommandProtocolError("COMMAND_NOT_FOUND", `No command registry is configured for ${step.commandId}`);
      }
      const child = await this.options.commandRegistry.get(step.commandId, step.commandVersion);
      if (!child) {
        throw new CommandProtocolError(
          "COMMAND_NOT_FOUND",
          `Command ${step.commandId}${step.commandVersion ? ` matching ${step.commandVersion}` : ""} was not found`
        );
      }
      if (step.commandVersion) assertCommandVersion(child, step.commandVersion, receiptId);
      await this.runCommandSteps(child, step.inputs ?? {}, receipt, receiptId, stack);
      return { action: {}, observation: await this.driver.observe() };
    }
    throw new CommandProtocolError("UNSUPPORTED_STEP", `Runner action ${String((step as CommandStep).action)} is not implemented`);
  }

  private async runRecovery(
    command: CommandDocument,
    failedStep: CommandStep,
    safety: StepSafetyAssessment | undefined,
    receipt: ExecutionReceipt,
    receiptId: string,
    stack: string[]
  ): Promise<void> {
    const recoveryCommandId = command.onFailure.recoveryCommandId;
    if (!recoveryCommandId) {
      throw new CommandProtocolError("RECOVERY_FAILED", `Command ${command.id} has no recovery command`);
    }
    const recoveryStep: CommandStep = {
      id: `${failedStep.id}-recovery`,
      action: "call",
      commandId: recoveryCommandId,
      safety: { risk: safety?.risk ?? command.safety.risk }
    };
    try {
      await this.runStep(
        command,
        recoveryStep,
        { stepId: recoveryStep.id, action: "call", risk: safety?.risk ?? command.safety.risk, requiresConfirmation: false },
        { behavior: "stop" },
        receipt,
        `${receiptId}:recovery`,
        stack
      );
    } catch (error) {
      throw new CommandProtocolError("RECOVERY_FAILED", `Recovery command ${recoveryCommandId} failed`, {
        details: protocolError(error, "DRIVER_ERROR")
      });
    }
  }

  private verifyStep(step: CommandStep, observation: DriverObservation): { passed: boolean; message?: string } {
    const verification = this.evaluateStep(step, observation);
    if (verification.passed) return verification;

    // A failed check on a degraded capture is far more likely to be missing pixels than a wrong
    // command. Say so here rather than letting it read as a broken step.
    const note = degradedCaptureNote(observation);
    if (!note) return verification;
    return { passed: false, message: `${verification.message ?? "condition did not match"} ${note}` };
  }

  private evaluateStep(step: CommandStep, observation: DriverObservation): { passed: boolean; message?: string } {
    if (step.action === "assert") return evaluateCondition(step.condition, observation);
    if (step.action === "waitFor") return evaluateCondition(step.condition, observation);
    if (step.expect) return evaluateCondition(step.expect, observation);
    return { passed: true };
  }

  private async waitFor(
    condition: Parameters<typeof evaluateCondition>[0],
    timeoutMs: number
  ): Promise<DriverObservation> {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const observation = await this.driver.observe();
      if (evaluateCondition(condition, observation).passed) return observation;
      if (Date.now() >= deadline) {
        throw new CommandProtocolError("WAIT_TIMEOUT", `Condition was not observed within ${timeoutMs} ms`);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, this.waitIntervalMs));
    }
  }

  /**
   * Ask a person, immediately before the action, and bind their answer to the screen they were
   * asked about. An approval given for one screen must not be spendable on a different one, so
   * the phone is observed again after the answer comes back and the approval is voided if
   * anything other than known-volatile content has moved.
   */
  private async confirmIfRequired(
    commandId: string,
    commandName: string,
    step: CommandStep,
    safety: StepSafetyAssessment | undefined,
    observed: DriverObservation,
    stepReceipt: StepReceipt
  ): Promise<void> {
    const required = step.action === "confirm" || safety?.requiresConfirmation === true;
    if (!required) {
      stepReceipt.confirmation = { required: false, outcome: "not-required" };
      return;
    }

    const risk = safety?.risk ?? "read";
    const message = step.action === "confirm" ? step.message : describeStep(step);
    const shown: ConfirmationShown = { message, risk, screen: observed };

    if (!this.options.confirmationProvider) {
      stepReceipt.confirmation = { required: true, outcome: "unavailable", shown };
      throw new CommandProtocolError(
        "CONFIRMATION_UNAVAILABLE",
        `Step ${step.id} requires human confirmation, but no confirmation provider is configured`
      );
    }

    const approvedScreen = bindScreen(observed);
    const decision = await this.options.confirmationProvider.confirm({
      command: { id: commandId, name: commandName },
      step,
      risk,
      message,
      observed
    });
    const actor = decision.actor === undefined ? {} : { actor: decision.actor };

    if (!decision.approved) {
      stepReceipt.confirmation = { required: true, outcome: "denied", shown, ...actor };
      throw new CommandProtocolError("CONFIRMATION_DENIED", `Human confirmation denied for step ${step.id}`);
    }

    const comparison = compareBinding(approvedScreen, bindScreen(await this.driver.observe()));
    if (!comparison.stable) {
      stepReceipt.confirmation = { required: true, outcome: "stale", shown, ...actor };
      throw new CommandProtocolError(
        "CONFIRMATION_STALE",
        `The iPhone screen changed after step ${step.id} was approved (${comparison.reason}), so nothing was done`
      );
    }

    stepReceipt.confirmation = {
      required: true,
      outcome: "approved",
      confirmedAt: this.now(),
      shown,
      ...actor
    };
  }

  private assertResumeSafe(
    receipt: ExecutionReceipt,
    receiptId: string,
    safety: StepSafetyAssessment | undefined
  ): void {
    const previous = [...receipt.steps].reverse().find((step) => step.id === receiptId && step.status !== "succeeded");
    if (!previous || !safety || riskRank[safety.risk] < riskRank.external) return;
    if (definitelyBeforeAction(previous.error?.code)) {
      return;
    }
    throw new CommandProtocolError(
      "RESUME_INVALID",
      `Step ${receiptId} may already have committed a ${safety.risk} action; explicit reconciliation is required before retrying`
    );
  }

  private assertRepeatSafe(
    receipt: ExecutionReceipt,
    receiptId: string,
    safety: StepSafetyAssessment | undefined
  ): void {
    const previous = [...receipt.steps].reverse().find((step) => step.id === receiptId && step.status !== "succeeded");
    if (!previous || !safety || riskRank[safety.risk] < riskRank.external || definitelyBeforeAction(previous.error?.code)) {
      return;
    }
    throw new CommandProtocolError(
      "COMMIT_OUTCOME_UNCERTAIN",
      `Step ${receiptId} may already have committed a ${safety.risk} action; automatic retry or recovery is unsafe`
    );
  }

  private recordStepFailure(stepReceipt: StepReceipt, error: unknown): void {
    const code = error instanceof CommandProtocolError ? error.code : undefined;
    // The confirmation gate records the outcome together with the sentence and the screen the
    // person was shown. Only fill in a bare outcome for a path that got here without one —
    // overwriting would throw away the part of the receipt that makes an answer auditable.
    if (!stepReceipt.confirmation) {
      if (code === "CONFIRMATION_DENIED") stepReceipt.confirmation = { required: true, outcome: "denied" };
      else if (code === "CONFIRMATION_UNAVAILABLE") stepReceipt.confirmation = { required: true, outcome: "unavailable" };
    }
    stepReceipt.status = code &&
      ["UNSUPPORTED_STEP", "COMMAND_NOT_FOUND", "INCOMPATIBLE_VERSION", "COMMAND_CYCLE"].includes(code)
      ? "unsupported"
      : code && ["CONFIRMATION_DENIED", "CONFIRMATION_UNAVAILABLE", "CONFIRMATION_STALE"].includes(code)
        ? "stopped"
        : "failed";
    stepReceipt.endedAt = this.now();
    stepReceipt.error = protocolError(error, "DRIVER_ERROR");
  }

  private initializeReceipt(
    command: CommandDocument,
    inputs: Record<string, unknown>,
    session: DriverSession,
    resumeFrom?: ExecutionReceipt
  ): ExecutionReceipt {
    if (!resumeFrom) {
      return {
        schemaVersion: "0.1",
        id: this.idFactory(),
        command: { id: command.id, schemaVersion: command.schemaVersion, version: command.version },
        status: "running",
        startedAt: this.now(),
        inputs,
        driver: receiptDriver(session),
        steps: []
      };
    }

    validateReceipt(resumeFrom);
    if (!["failed", "stopped", "unsupported"].includes(resumeFrom.status)) {
      throw new CommandProtocolError("RESUME_INVALID", `Receipt ${resumeFrom.id} is ${resumeFrom.status}, not resumable`);
    }
    if (resumeFrom.command.id !== command.id || (resumeFrom.command.version ?? "1.0.0") !== command.version) {
      throw new CommandProtocolError(
        "RESUME_INVALID",
        `Receipt ${resumeFrom.id} belongs to ${resumeFrom.command.id}@${resumeFrom.command.version ?? "1.0.0"}, not ${command.id}@${command.version}`
      );
    }
    if (!sameJson(resumeFrom.inputs, inputs)) {
      throw new CommandProtocolError("RESUME_INVALID", `Receipt ${resumeFrom.id} inputs do not match this run`);
    }

    const receipt = structuredClone(resumeFrom);
    receipt.status = "running";
    receipt.driver = receiptDriver(session);
    delete receipt.endedAt;
    delete receipt.error;
    return receipt;
  }

  private async persist(receipt: ExecutionReceipt): Promise<void> {
    validateReceipt(receipt);
    await this.options.receiptSink?.write(receipt);
  }

  private async stopSession(): Promise<void> {
    try {
      await this.driver.stopSession?.();
    } catch {
      // Session cleanup must overwrite neither the outcome nor its durable receipt.
    }
  }

  private terminalReceipt(
    inputs: Record<string, unknown>,
    command: RunRequest["command"],
    startedAt: string,
    status: "failed",
    driver: ExecutionReceipt["driver"],
    error: ReceiptError
  ): ExecutionReceipt {
    return {
      schemaVersion: "0.1",
      id: this.idFactory(),
      command: { id: command.id, schemaVersion: command.schemaVersion, version: command.version },
      status,
      startedAt,
      endedAt: this.now(),
      inputs,
      driver,
      steps: [],
      error
    };
  }

  private now(): string {
    return this.clock().toISOString();
  }
}

function protocolError(error: unknown, fallbackCode: string): ReceiptError {
  if (error instanceof CommandProtocolError) return error.toJSON();
  return {
    code: fallbackCode,
    message: error instanceof Error ? error.message : String(error)
  };
}

/**
 * Every Mac that can run iPhone Mirroring has a 2x display. A lower reading means the mirror
 * window was on something that is not — an AirPlay TV, Sidecar, an external 1080p monitor — and
 * none of those announce themselves.
 */
const expectedCaptureScale = 2;

export function degradedCaptureNote(observation: DriverObservation): string | undefined {
  const scale = observation.captureScale;
  if (scale === undefined || scale >= expectedCaptureScale) return undefined;
  return `The screen was captured at ${scale}x instead of ${expectedCaptureScale}x, so there may not have been enough detail to read it. Check whether this Mac's display is being mirrored or extended to another screen.`;
}

function terminalStatus(error: ReceiptError, behavior: string): ExecutionReceipt["status"] {
  if (["UNSUPPORTED_CAPABILITY", "UNSUPPORTED_STEP", "COMMAND_NOT_FOUND", "INCOMPATIBLE_VERSION", "COMMAND_CYCLE"].includes(error.code)) {
    return "unsupported";
  }
  // A denied, unavailable, or voided approval all mean the runner deliberately did nothing.
  if (
    error.code === "CONFIRMATION_DENIED" ||
    error.code === "CONFIRMATION_UNAVAILABLE" ||
    error.code === "CONFIRMATION_STALE" ||
    behavior === "requestHelp"
  ) {
    return "stopped";
  }
  return "failed";
}

function receiptDriver(session: DriverSession): ExecutionReceipt["driver"] {
  return {
    id: session.id,
    ...(session.version ? { version: session.version } : {}),
    actions: [...session.capabilities.actions],
    observations: [...session.capabilities.observations]
  };
}

function hasSucceeded(receipt: ExecutionReceipt, receiptId: string): boolean {
  return receipt.steps.some((step) => step.id === receiptId && step.status === "succeeded");
}

function hasCompletedInScope(receipt: ExecutionReceipt, prefix: string): boolean {
  return receipt.steps.some((step) =>
    step.status === "succeeded" && (prefix ? step.id.startsWith(`${prefix}:`) : true)
  );
}

function nextAttempt(receipt: ExecutionReceipt, receiptId: string): number {
  return Math.max(0, ...receipt.steps.filter((step) => step.id === receiptId).map((step) => step.attempt)) + 1;
}

function sameJson(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function definitelyBeforeAction(errorCode: string | undefined): boolean {
  return [
    "PRECONDITION_FAILED",
    "CONFIRMATION_DENIED",
    "CONFIRMATION_UNAVAILABLE",
    "TARGET_NOT_FOUND",
    "TARGET_CONFIDENCE",
    "UNSUPPORTED_STEP",
    "COMMAND_NOT_FOUND",
    "INCOMPATIBLE_VERSION",
    "COMMAND_CYCLE"
  ].includes(errorCode ?? "");
}
