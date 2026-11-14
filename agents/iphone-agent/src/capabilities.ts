import { CommandProtocolError } from "./errors.js";
import type {
  CapabilityCheck,
  CommandDocument,
  CommandStep,
  DriverAction,
  DriverCapabilities,
  MissingCapability,
  ObservationCapability,
  ObservationConstraint,
  RequiredCapabilities
} from "./types.js";

const driverActions = new Set<CommandStep["action"]>(["openApp", "tap", "typeText", "swipe", "press"]);

export function requiredCapabilities(command: CommandDocument): RequiredCapabilities {
  const actions = new Set<DriverAction>();
  const observations = new Set<ObservationCapability>();

  command.preconditions.forEach((condition) => collectObservationCapabilities(condition, observations));
  command.postconditions.forEach((condition) => collectObservationCapabilities(condition, observations));

  for (const step of command.steps) {
    if (driverActions.has(step.action)) {
      actions.add(step.action as DriverAction);
    }
    if ("target" in step && step.target) {
      observations.add("target");
    }
    if (step.action === "capture") observations.add("screenshot");
    if (step.precondition) {
      collectObservationCapabilities(step.precondition, observations);
    }
    if (step.expect) {
      collectObservationCapabilities(step.expect, observations);
    }
    if (step.action === "waitFor" || step.action === "assert") {
      collectObservationCapabilities(step.condition, observations);
    }
  }

  return {
    actions: [...actions].sort(),
    observations: [...observations].sort()
  };
}

export function checkCapabilities(
  command: CommandDocument,
  available: DriverCapabilities
): CapabilityCheck {
  const required = requiredCapabilities(command);
  const availableActions = new Set(available.actions);
  const availableObservations = new Set(available.observations);
  const missing: MissingCapability[] = [];

  for (const action of required.actions) {
    if (!availableActions.has(action)) {
      missing.push({
        kind: "action",
        capability: action,
        stepIds: command.steps.filter((step) => step.action === action).map((step) => step.id)
      });
    }
  }

  for (const observation of required.observations) {
    if (!availableObservations.has(observation)) {
      missing.push({
        kind: "observation",
        capability: observation,
        stepIds: stepsRequiringObservation(command, observation)
      });
    }
  }

  return { supported: missing.length === 0, required, missing };
}

export function assertCapabilities(command: CommandDocument, available: DriverCapabilities): void {
  const result = checkCapabilities(command, available);
  if (!result.supported) {
    throw new CommandProtocolError(
      "UNSUPPORTED_CAPABILITY",
      `Driver is missing required capabilities: ${result.missing
        .map((item) => `${item.kind}:${item.capability}`)
        .join(", ")}`,
      { details: result }
    );
  }
}

function collectObservationCapabilities(
  condition: ObservationConstraint,
  capabilities: Set<ObservationCapability>
): void {
  if (condition.screenText !== undefined) capabilities.add("screenText");
  if (condition.app !== undefined) capabilities.add("app");
  if (condition.target !== undefined) capabilities.add("target");
  condition.all?.forEach((child) => collectObservationCapabilities(child, capabilities));
  condition.any?.forEach((child) => collectObservationCapabilities(child, capabilities));
  if (condition.not) collectObservationCapabilities(condition.not, capabilities);
}

function stepsRequiringObservation(
  command: CommandDocument,
  capability: ObservationCapability
): string[] {
  const matches = (condition?: ObservationConstraint): boolean => {
    if (!condition) return false;
    if (capability === "screenText" && condition.screenText !== undefined) return true;
    if (capability === "app" && condition.app !== undefined) return true;
    if (capability === "target" && condition.target !== undefined) return true;
    return (
      condition.all?.some(matches) === true ||
      condition.any?.some(matches) === true ||
      (condition.not ? matches(condition.not) : false)
    );
  };

  return command.steps
    .filter((step) => {
      if (capability === "screenshot" && step.action === "capture") return true;
      if (capability === "target" && "target" in step && step.target) return true;
      if (matches(step.precondition) || matches(step.expect)) return true;
      return (step.action === "waitFor" || step.action === "assert") && matches(step.condition);
    })
    .map((step) => step.id);
}
