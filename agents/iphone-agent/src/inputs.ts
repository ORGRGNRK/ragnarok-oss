import { CommandProtocolError } from "./errors.js";
import type { CommandDocument, InputDefinition, PreparedCommand } from "./types.js";
import { validateCommand } from "./validator.js";

const variablePattern = /\$\{input\.([A-Za-z_][A-Za-z0-9_.-]*)\}/g;
const exactVariablePattern = /^\$\{input\.([A-Za-z_][A-Za-z0-9_.-]*)\}$/;

export function prepareCommand(
  command: CommandDocument,
  providedInputs: Record<string, unknown> = {}
): PreparedCommand {
  const inputs = prepareInputs(command.inputs, providedInputs);
  const commandClone = structuredClone(command) as unknown as Record<string, unknown>;

  for (const [key, value] of Object.entries(commandClone)) {
    if (key !== "inputs") {
      commandClone[key] = substitute(value, inputs, `/${escapePath(key)}`);
    }
  }

  validateCommand(commandClone);
  return {
    command: commandClone,
    inputs,
    redactedInputs: redactInputs(command.inputs, inputs)
  };
}

export function prepareInputs(
  definitions: Record<string, InputDefinition>,
  providedInputs: Record<string, unknown>
): Record<string, unknown> {
  for (const inputName of Object.keys(providedInputs)) {
    if (!(inputName in definitions)) {
      throw new CommandProtocolError("INPUT_UNKNOWN", `Unknown input: ${inputName}`, {
        path: `/inputs/${escapePath(inputName)}`
      });
    }
  }

  const prepared: Record<string, unknown> = {};
  for (const [inputName, definition] of Object.entries(definitions)) {
    const supplied = Object.prototype.hasOwnProperty.call(providedInputs, inputName);
    const hasDefault = Object.prototype.hasOwnProperty.call(definition, "default");

    if (!supplied && !hasDefault) {
      if (definition.required !== false) {
        throw new CommandProtocolError("INPUT_MISSING", `Missing required input: ${inputName}`, {
          path: `/inputs/${escapePath(inputName)}`
        });
      }
      continue;
    }

    const value = supplied ? providedInputs[inputName] : definition.default;
    if (!matchesType(value, definition.type)) {
      throw new CommandProtocolError(
        "INPUT_TYPE",
        `Input ${inputName} must be ${definition.type}; received ${describeType(value)}`,
        { path: `/inputs/${escapePath(inputName)}` }
      );
    }
    prepared[inputName] = value;
  }

  return prepared;
}

export function redactInputs(
  definitions: Record<string, InputDefinition>,
  inputs: Record<string, unknown>
): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(inputs).map(([name, value]) => [name, definitions[name]?.secret ? "[REDACTED]" : value])
  );
}

function substitute(value: unknown, inputs: Record<string, unknown>, path: string): unknown {
  if (typeof value === "string") {
    const exact = value.match(exactVariablePattern);
    if (exact) {
      return variableValue(exact[1], inputs, path);
    }

    return value.replace(variablePattern, (_match, inputName: string) => {
      const replacement = variableValue(inputName, inputs, path);
      if (typeof replacement === "object" || typeof replacement === "undefined") {
        throw new CommandProtocolError(
          "VARIABLE_INVALID",
          `Input ${inputName} cannot be embedded in text because it is not a scalar value`,
          { path }
        );
      }
      return String(replacement);
    });
  }

  if (Array.isArray(value)) {
    return value.map((item, index) => substitute(item, inputs, `${path}/${index}`));
  }

  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        substitute(item, inputs, `${path}/${escapePath(key)}`)
      ])
    );
  }

  return value;
}

function variableValue(name: string, inputs: Record<string, unknown>, path: string): unknown {
  if (!Object.prototype.hasOwnProperty.call(inputs, name)) {
    throw new CommandProtocolError("INPUT_MISSING", `Variable references unavailable input: ${name}`, {
      path
    });
  }
  return inputs[name];
}

function matchesType(value: unknown, expected: InputDefinition["type"]): boolean {
  switch (expected) {
    case "string":
      return typeof value === "string";
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "boolean":
      return typeof value === "boolean";
  }
}

function describeType(value: unknown): string {
  if (typeof value === "number" && Number.isInteger(value)) {
    return "integer";
  }
  if (value === null) {
    return "null";
  }
  if (Array.isArray(value)) {
    return "array";
  }
  return typeof value;
}

function escapePath(segment: string): string {
  return segment.replaceAll("~", "~0").replaceAll("/", "~1");
}
