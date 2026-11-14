import { checkCapabilities } from "./capabilities.js";
import { assertCommandVersion } from "./catalog.js";
import { CommandProtocolError, type ProtocolErrorCode } from "./errors.js";
import { prepareCommand } from "./inputs.js";
import { assessSafety } from "./policy.js";
import type { CommandRegistry } from "./runtime-types.js";
import type {
  ActionName,
  CommandDocument,
  DriverAction,
  DriverCapabilities,
  MissingCapability,
  ObservationCapability,
  RiskClass
} from "./types.js";

export interface DryRunStep {
  path: string;
  commandId: string;
  commandVersion: string;
  stepId: string;
  action: ActionName;
  risk: RiskClass;
  requiresConfirmation: boolean;
}

export interface DryRunError {
  code: ProtocolErrorCode;
  message: string;
  path?: string;
}

export interface DryRunReport {
  command: { id: string; version: string; schemaVersion: "0.1" };
  inputs: Record<string, unknown>;
  valid: boolean;
  supported: boolean;
  actionsExecuted: 0;
  steps: DryRunStep[];
  requiredCapabilities: {
    actions: DriverAction[];
    observations: ObservationCapability[];
  };
  missingCapabilities: MissingCapability[];
  confirmationPaths: string[];
  errors: DryRunError[];
}

export interface DryRunOptions {
  capabilities: DriverCapabilities;
  registry?: CommandRegistry;
  machineSafetyFloor?: RiskClass;
}

export async function dryRunCommand(
  command: CommandDocument,
  inputs: Record<string, unknown> = {},
  options: DryRunOptions
): Promise<DryRunReport> {
  const prepared = prepareCommand(command, inputs);
  const steps: DryRunStep[] = [];
  const errors: DryRunError[] = [];
  const actionSet = new Set<DriverAction>();
  const observationSet = new Set<ObservationCapability>();
  const missing: MissingCapability[] = [];

  await visit(
    prepared.command,
    prepared.inputs,
    prepared.command.id,
    [],
    options,
    steps,
    errors,
    actionSet,
    observationSet,
    missing
  );

  return {
    command: {
      id: prepared.command.id,
      version: prepared.command.version,
      schemaVersion: prepared.command.schemaVersion
    },
    inputs: prepared.redactedInputs,
    valid: errors.length === 0,
    supported: errors.length === 0 && missing.length === 0,
    actionsExecuted: 0,
    steps,
    requiredCapabilities: {
      actions: [...actionSet].sort(),
      observations: [...observationSet].sort()
    },
    missingCapabilities: mergeMissing(missing),
    confirmationPaths: steps.filter((step) => step.requiresConfirmation).map((step) => step.path),
    errors
  };
}

async function visit(
  command: CommandDocument,
  inputs: Record<string, unknown>,
  path: string,
  stack: string[],
  options: DryRunOptions,
  steps: DryRunStep[],
  errors: DryRunError[],
  actionSet: Set<DriverAction>,
  observationSet: Set<ObservationCapability>,
  missing: MissingCapability[]
): Promise<void> {
  const stackKey = `${command.id}@${command.version}`;
  if (stack.includes(stackKey)) {
    errors.push({ code: "COMMAND_CYCLE", message: `Command cycle detected: ${[...stack, stackKey].join(" -> ")}`, path });
    return;
  }

  const prepared = prepareCommand(command, inputs);
  const safety = assessSafety(prepared.command, options.machineSafetyFloor);
  const capability = checkCapabilities(prepared.command, options.capabilities);
  capability.required.actions.forEach((action) => actionSet.add(action));
  capability.required.observations.forEach((observation) => observationSet.add(observation));
  missing.push(...capability.missing.map((item) => ({
    ...item,
    stepIds: item.stepIds.map((stepId) => `${path}:${stepId}`)
  })));

  for (const step of prepared.command.steps) {
    const stepPath = `${path}:${step.id}`;
    const assessment = safety.steps.find((candidate) => candidate.stepId === step.id);
    steps.push({
      path: stepPath,
      commandId: prepared.command.id,
      commandVersion: prepared.command.version,
      stepId: step.id,
      action: step.action,
      risk: assessment?.risk ?? prepared.command.safety.risk,
      requiresConfirmation: assessment?.requiresConfirmation ?? false
    });

    if (step.action !== "call") continue;
    if (!options.registry) {
      errors.push({ code: "COMMAND_NOT_FOUND", message: `No command registry is configured for ${step.commandId}`, path: stepPath });
      continue;
    }
    const child = await options.registry.get(step.commandId, step.commandVersion);
    if (!child) {
      errors.push({
        code: "COMMAND_NOT_FOUND",
        message: `Command ${step.commandId}${step.commandVersion ? ` matching ${step.commandVersion}` : ""} was not found`,
        path: stepPath
      });
      continue;
    }
    try {
      if (step.commandVersion) assertCommandVersion(child, step.commandVersion, stepPath);
      await visit(
        child,
        step.inputs ?? {},
        stepPath,
        [...stack, stackKey],
        options,
        steps,
        errors,
        actionSet,
        observationSet,
        missing
      );
    } catch (error) {
      errors.push(asDryRunError(error, stepPath));
    }
  }

  if (prepared.command.onFailure.behavior === "recover" && prepared.command.onFailure.recoveryCommandId) {
    const recoveryPath = `${path}:recovery`;
    const recovery = await options.registry?.get(prepared.command.onFailure.recoveryCommandId);
    if (!recovery) {
      errors.push({ code: "COMMAND_NOT_FOUND", message: `Recovery command ${prepared.command.onFailure.recoveryCommandId} was not found`, path: recoveryPath });
    } else {
      try {
        await visit(recovery, {}, recoveryPath, [...stack, stackKey], options, steps, errors, actionSet, observationSet, missing);
      } catch (error) {
        errors.push(asDryRunError(error, recoveryPath));
      }
    }
  }
}

function mergeMissing(items: MissingCapability[]): MissingCapability[] {
  const merged = new Map<string, MissingCapability>();
  for (const item of items) {
    const key = `${item.kind}:${item.capability}`;
    const existing = merged.get(key);
    if (existing) existing.stepIds.push(...item.stepIds);
    else merged.set(key, structuredClone(item));
  }
  return [...merged.values()].map((item) => ({ ...item, stepIds: [...new Set(item.stepIds)].sort() }));
}

function asDryRunError(error: unknown, path: string): DryRunError {
  if (error instanceof CommandProtocolError) return { code: error.code, message: error.message, path: error.path ?? path };
  return { code: "SCHEMA_INVALID", message: error instanceof Error ? error.message : String(error), path };
}
