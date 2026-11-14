import { CommandProtocolError } from "./errors.js";
import type {
  CommandDocument,
  CommandStep,
  FailureBehavior,
  InputDefinition,
  RiskClass
} from "./types.js";
import { normalizeCommand, validateCommand } from "./validator.js";

export interface PromptChoice<T extends string> {
  label: string;
  value: T;
}

export interface AuthorPrompt {
  text(message: string, defaultValue?: string): Promise<string>;
  select<T extends string>(message: string, choices: PromptChoice<T>[]): Promise<T>;
  confirm(message: string, defaultValue?: boolean): Promise<boolean>;
}

export async function createGuidedCommand(prompt: AuthorPrompt): Promise<CommandDocument> {
  const name = required(await prompt.text("Command name"), "Command name");
  const defaultId = `com.yggdrasil.iphone.${slug(name)}`;
  const id = required(await prompt.text("Command id", defaultId), "Command id");
  const description = (await prompt.text("Description (optional)")).trim();
  const risk = await prompt.select<RiskClass>("Overall risk", riskChoices);
  const requiresConfirmation = await prompt.confirm(
    "Require confirmation even if the policy would not?",
    riskRank(risk) >= riskRank("external")
  );
  const inputs = await collectInputs(prompt);
  const steps = await collectSteps(prompt);
  const postconditionText = (await prompt.text("Final screen text to verify (optional)")).trim();
  const onFailure = await collectFailureBehavior(prompt);

  const proposed = normalizeCommand({
    schemaVersion: "0.1",
    id,
    name,
    ...(description ? { description } : {}),
    inputs,
    safety: { risk, requiresConfirmation },
    steps,
    onFailure,
    postconditions: postconditionText ? [{ screenText: postconditionText }] : []
  });
  validateCommand(proposed);
  return proposed;
}

const riskChoices: PromptChoice<RiskClass>[] = [
  { label: "Read only", value: "read" },
  { label: "Reversible", value: "reversible" },
  { label: "External send/change", value: "external" },
  { label: "Financial", value: "financial" },
  { label: "Destructive", value: "destructive" },
  { label: "Credential", value: "credential" }
];

async function collectInputs(prompt: AuthorPrompt): Promise<Record<string, InputDefinition>> {
  const inputs: Record<string, InputDefinition> = {};
  while (await prompt.confirm("Add a runtime input?", false)) {
    const name = required(await prompt.text("Input name"), "Input name");
    if (name in inputs) throw new CommandProtocolError("SCHEMA_INVALID", `Duplicate input: ${name}`);
    const type = await prompt.select<InputDefinition["type"]>("Input type", [
      { label: "Text", value: "string" },
      { label: "Number", value: "number" },
      { label: "Integer", value: "integer" },
      { label: "True/false", value: "boolean" }
    ]);
    const secret = await prompt.confirm("Is this input secret?", false);
    const requiredInput = await prompt.confirm("Is this input required?", true);
    inputs[name] = { type, secret, required: requiredInput };
  }
  return inputs;
}

async function collectSteps(prompt: AuthorPrompt): Promise<CommandStep[]> {
  const steps: CommandStep[] = [];
  do {
    const action = await prompt.select<CommandStep["action"]>("Action", [
      { label: "Open app", value: "openApp" },
      { label: "Tap target", value: "tap" },
      { label: "Type text", value: "typeText" },
      { label: "Swipe", value: "swipe" },
      { label: "Press button", value: "press" },
      { label: "Capture screenshot", value: "capture" },
      { label: "Wait for text", value: "waitFor" },
      { label: "Assert text", value: "assert" },
      { label: "Request confirmation", value: "confirm" },
      { label: "Call another command", value: "call" }
    ]);
    const defaultStepId = `${action}-${steps.length + 1}`;
    const id = required(await prompt.text("Step id", defaultStepId), "Step id");
    if (steps.some((step) => step.id === id)) {
      throw new CommandProtocolError("SCHEMA_INVALID", `Duplicate step id: ${id}`);
    }
    steps.push(await collectStep(prompt, action, id));
  } while (await prompt.confirm("Add another step?", false));
  return steps;
}

async function collectStep(
  prompt: AuthorPrompt,
  action: CommandStep["action"],
  id: string
): Promise<CommandStep> {
  switch (action) {
    case "openApp": {
      const appName = required(await prompt.text("App name"), "App name");
      const expected = (await prompt.text("Expected screen text", appName)).trim();
      return { id, action, app: { name: appName }, ...(expected ? { expect: { screenText: expected } } : {}) };
    }
    case "tap": {
      const label = required(await prompt.text("Target label or visible text"), "Target label");
      const within = (await prompt.text("Target container (optional)")).trim();
      return { id, action, target: { label, ...(within ? { within } : {}) } };
    }
    case "typeText": {
      const text = await prompt.text("Text or ${input.name} variable");
      const targetLabel = (await prompt.text("Field label (optional)")).trim();
      return { id, action, text, ...(targetLabel ? { target: { role: "textField", label: targetLabel } } : {}) };
    }
    case "swipe": {
      const direction = await prompt.select<"up" | "down" | "left" | "right">("Direction", [
        { label: "Up", value: "up" },
        { label: "Down", value: "down" },
        { label: "Left", value: "left" },
        { label: "Right", value: "right" }
      ]);
      return { id, action, direction };
    }
    case "press": {
      const button = await prompt.select<"home" | "appSwitcher" | "back">("Button", [
        { label: "Home", value: "home" },
        { label: "App Switcher", value: "appSwitcher" },
        { label: "Back", value: "back" }
      ]);
      return { id, action, button };
    }
    case "capture": {
      const label = required(await prompt.text("Screenshot label", id), "Screenshot label");
      return { id, action, label };
    }
    case "waitFor": {
      const screenText = required(await prompt.text("Screen text to wait for"), "Screen text");
      const timeoutMs = integer(await prompt.text("Timeout in milliseconds", "10000"), "Timeout");
      return { id, action, condition: { screenText }, timeoutMs };
    }
    case "assert": {
      const screenText = required(await prompt.text("Screen text to assert"), "Screen text");
      return { id, action, condition: { screenText } };
    }
    case "confirm": {
      const message = required(await prompt.text("Confirmation message"), "Confirmation message");
      return { id, action, message };
    }
    case "call": {
      const commandId = required(await prompt.text("Command id to call"), "Called command id");
      return { id, action, commandId };
    }
  }
}

async function collectFailureBehavior(prompt: AuthorPrompt): Promise<FailureBehavior> {
  const behavior = await prompt.select<FailureBehavior["behavior"]>("If a step fails", [
    { label: "Stop", value: "stop" },
    { label: "Retry with a bound", value: "retry" },
    { label: "Request help", value: "requestHelp" },
    { label: "Run a recovery command", value: "recover" }
  ]);
  if (behavior === "retry") {
    return { behavior, maxAttempts: integer(await prompt.text("Maximum attempts", "2"), "Maximum attempts") };
  }
  if (behavior === "recover") {
    return { behavior, recoveryCommandId: required(await prompt.text("Recovery command id"), "Recovery command id") };
  }
  return { behavior };
}

function required(value: string, label: string): string {
  const trimmed = value.trim();
  if (!trimmed) throw new CommandProtocolError("PARSE_ERROR", `${label} is required`);
  return trimmed;
}

function integer(value: string, label: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new CommandProtocolError("PARSE_ERROR", `${label} must be a positive integer`);
  }
  return parsed;
}

function slug(value: string): string {
  return value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "command";
}

function riskRank(risk: RiskClass): number {
  return ["read", "reversible", "external", "financial", "destructive", "credential"].indexOf(risk);
}
