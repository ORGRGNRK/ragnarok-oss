import { readFileSync } from "node:fs";

import { Ajv2020, type ErrorObject, type ValidateFunction } from "ajv/dist/2020.js";
import addFormatsImport from "ajv-formats";
import { valid, validRange } from "semver";
import { parseDocument } from "yaml";

import { CommandProtocolError } from "./errors.js";
import type { CommandDocument } from "./types.js";

export type SourceFormat = "json" | "yaml";

const commandSchema = readSchema("command.schema.json");
const receiptSchema = readSchema("receipt.schema.json");

const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
const addFormats = addFormatsImport as unknown as (instance: Ajv2020) => Ajv2020;
addFormats(ajv);

const validateCommandSchema = ajv.compile<CommandDocument>(commandSchema);
const validateReceiptSchema = ajv.compile(receiptSchema);

function readSchema(filename: string): object {
  return JSON.parse(readFileSync(new URL(`../schemas/${filename}`, import.meta.url), "utf8")) as object;
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function schemaFailure(label: string, validator: ValidateFunction): CommandProtocolError {
  const errors = (validator.errors ?? []).map((error: ErrorObject) => ({
    path: error.instancePath || "/",
    keyword: error.keyword,
    message: error.message,
    params: error.params
  }));
  const first = errors[0];
  return new CommandProtocolError(
    "SCHEMA_INVALID",
    `${label} failed schema validation${first ? ` at ${first.path}: ${first.message}` : ""}`,
    { path: first?.path, details: errors }
  );
}

export function parseSource(source: string, format?: SourceFormat): unknown {
  const selectedFormat = format ?? (source.trimStart().startsWith("{") ? "json" : "yaml");

  if (selectedFormat === "json") {
    try {
      return JSON.parse(source) as unknown;
    } catch (error) {
      throw new CommandProtocolError("PARSE_ERROR", `Invalid JSON: ${errorMessage(error)}`);
    }
  }

  try {
    const document = parseDocument(source, { prettyErrors: true, uniqueKeys: true });
    if (document.errors.length > 0) {
      throw new Error(document.errors.map((error) => error.message).join("; "));
    }
    return document.toJS({ maxAliasCount: 50 }) as unknown;
  } catch (error) {
    throw new CommandProtocolError("PARSE_ERROR", `Invalid YAML: ${errorMessage(error)}`);
  }
}

export function normalizeCommand(value: unknown): unknown {
  if (!isRecord(value)) {
    return value;
  }

  const normalized = clone(value);
  normalized.inputs ??= {};
  normalized.version ??= "1.0.0";
  normalized.preconditions ??= [];
  normalized.postconditions ??= [];
  normalized.onFailure ??= { behavior: "stop" };

  if (isRecord(normalized.safety)) {
    normalized.safety.requiresConfirmation ??= false;
  }

  return normalized;
}

export function validateCommand(value: unknown): asserts value is CommandDocument {
  if (!validateCommandSchema(value)) {
    throw schemaFailure("Command", validateCommandSchema);
  }
  validateCommandSemantics(value as CommandDocument);
}

export function parseCommand(source: string, format?: SourceFormat): CommandDocument {
  const normalized = normalizeCommand(parseSource(source, format));
  validateCommand(normalized);
  return normalized;
}

export function validateReceipt(value: unknown): void {
  if (!validateReceiptSchema(value)) {
    throw schemaFailure("Receipt", validateReceiptSchema);
  }
}

export function getCommandSchema(): object {
  return clone(commandSchema);
}

export function getReceiptSchema(): object {
  return clone(receiptSchema);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function validateCommandSemantics(command: CommandDocument): void {
  if (!valid(command.version)) {
    throw new CommandProtocolError("SCHEMA_INVALID", `Command version must be valid semantic version: ${command.version}`, {
      path: "/version"
    });
  }
  const stepIds = new Set<string>();
  for (const step of command.steps) {
    if (stepIds.has(step.id)) {
      throw new CommandProtocolError("SCHEMA_INVALID", `Command contains duplicate step id: ${step.id}`, {
        path: "/steps"
      });
    }
    stepIds.add(step.id);
    if (step.action === "call" && step.commandVersion !== undefined && !validRange(step.commandVersion)) {
      throw new CommandProtocolError(
        "SCHEMA_INVALID",
        `Call step ${step.id} has invalid command version range: ${step.commandVersion}`,
        { path: `/steps/${command.steps.indexOf(step)}/commandVersion` }
      );
    }
  }

  for (const [name, definition] of Object.entries(command.inputs)) {
    if (Object.prototype.hasOwnProperty.call(definition, "default") && !inputMatchesType(definition.default, definition.type)) {
      throw new CommandProtocolError(
        "SCHEMA_INVALID",
        `Default for input ${name} must be ${definition.type}`,
        { path: `/inputs/${escapePath(name)}/default` }
      );
    }
  }
}

function inputMatchesType(value: unknown, type: CommandDocument["inputs"][string]["type"]): boolean {
  switch (type) {
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

function escapePath(segment: string): string {
  return segment.replaceAll("~", "~0").replaceAll("/", "~1");
}
