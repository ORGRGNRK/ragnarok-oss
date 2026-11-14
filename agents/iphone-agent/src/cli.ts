#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { extname } from "node:path";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";

import {
  RuleBasedNaturalLanguageProvider,
  ValidatingNaturalLanguageAuthor,
  serializeCommand,
  type CommandFormat
} from "./authoring.js";
import { DirectoryCommandRegistry } from "./catalog.js";
import { dryRunCommand } from "./dry-run.js";
import { CommandProtocolError } from "./errors.js";
import { createGuidedCommand, type AuthorPrompt, type PromptChoice } from "./guided-author.js";
import type { DriverCapabilities } from "./types.js";
import { parseCommand, type SourceFormat } from "./validator.js";

const help = `iphone-command — portable iPhone command authoring

Usage:
  iphone-command create [--format json|yaml] [--output FILE] [--force]
  iphone-command from-text "open Settings" [--format json|yaml] [--output FILE] [--force]
  iphone-command validate FILE
  iphone-command convert FILE --to json|yaml [--output FILE] [--force]
  iphone-command dry-run FILE --capabilities FILE [--library DIR] [--inputs FILE]
  iphone-command help

Commands:
  create      Guided, non-AI command creation.
  from-text   Safe built-in natural-language patterns; no network or API key.
  validate    Parse, normalize, and validate a JSON or YAML command.
  convert     Import JSON/YAML and export canonical JSON or YAML.
  dry-run     Validate the full command tree and capabilities without phone actions.
`;

async function main(args: string[]): Promise<void> {
  const command = args[0] ?? "help";
  if (command === "help" || command === "--help" || command === "-h") {
    stdout.write(help);
    return;
  }

  if (command === "create") {
    const readline = createInterface({ input: stdin, output: stdout });
    try {
      const authored = await createGuidedCommand(new ReadlineAuthorPrompt(readline));
      await emit(authored, outputFormat(args, "json"), option(args, "--output"), flag(args, "--force"));
    } finally {
      readline.close();
    }
    return;
  }

  if (command === "from-text") {
    const text = positionals(args.slice(1)).join(" ").trim();
    if (!text) throw usageError("from-text requires a quoted instruction");
    const author = new ValidatingNaturalLanguageAuthor(new RuleBasedNaturalLanguageProvider());
    const authored = await author.author(text);
    await emit(authored, outputFormat(args, "json"), option(args, "--output"), flag(args, "--force"));
    return;
  }

  if (command === "validate") {
    const path = positionals(args.slice(1))[0];
    if (!path) throw usageError("validate requires a file path");
    const authored = await load(path);
    stdout.write(`Valid command: ${authored.id} (${authored.steps.length} step${authored.steps.length === 1 ? "" : "s"})\n`);
    return;
  }

  if (command === "convert") {
    const path = positionals(args.slice(1))[0];
    if (!path) throw usageError("convert requires a file path");
    const format = option(args, "--to");
    if (format !== "json" && format !== "yaml") throw usageError("convert requires --to json or --to yaml");
    const authored = await load(path);
    await emit(authored, format, option(args, "--output"), flag(args, "--force"));
    return;
  }

  if (command === "dry-run") {
    const path = positionals(args.slice(1))[0];
    if (!path) throw usageError("dry-run requires a command file path");
    const capabilitiesPath = option(args, "--capabilities");
    if (!capabilitiesPath) throw usageError("dry-run requires --capabilities FILE");
    const authored = await load(path);
    const capabilities = await loadCapabilities(capabilitiesPath);
    const inputsPath = option(args, "--inputs");
    const inputs = inputsPath ? await loadObject(inputsPath, "inputs") : {};
    const library = option(args, "--library");
    const report = await dryRunCommand(authored, inputs, {
      capabilities,
      ...(library ? { registry: new DirectoryCommandRegistry(library) } : {})
    });
    stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (!report.supported) process.exitCode = 2;
    return;
  }

  throw usageError(`Unknown command: ${command}`);
}

class ReadlineAuthorPrompt implements AuthorPrompt {
  constructor(private readonly readline: ReturnType<typeof createInterface>) {}

  async text(message: string, defaultValue?: string): Promise<string> {
    const answer = await this.readline.question(`${message}${defaultValue === undefined ? "" : ` [${defaultValue}]`}: `);
    return answer.trim() || defaultValue || "";
  }

  async select<T extends string>(message: string, choices: PromptChoice<T>[]): Promise<T> {
    stdout.write(`${message}:\n`);
    choices.forEach((choice, index) => stdout.write(`  ${index + 1}. ${choice.label}\n`));
    while (true) {
      const answer = await this.readline.question("Choose a number: ");
      const index = Number(answer) - 1;
      const choice = choices[index];
      if (choice) return choice.value;
      stdout.write(`Choose a number from 1 to ${choices.length}.\n`);
    }
  }

  async confirm(message: string, defaultValue = false): Promise<boolean> {
    const suffix = defaultValue ? "Y/n" : "y/N";
    while (true) {
      const answer = (await this.readline.question(`${message} [${suffix}]: `)).trim().toLocaleLowerCase();
      if (!answer) return defaultValue;
      if (answer === "y" || answer === "yes") return true;
      if (answer === "n" || answer === "no") return false;
      stdout.write("Enter yes or no.\n");
    }
  }
}

async function load(path: string) {
  const source = await readFile(path, "utf8");
  return parseCommand(source, sourceFormat(path));
}

async function loadCapabilities(path: string): Promise<DriverCapabilities> {
  const value = await loadObject(path, "capabilities");
  const allowedActions = new Set(["openApp", "tap", "typeText", "swipe", "press"]);
  const allowedObservations = new Set(["screenshot", "screenText", "app", "target"]);
  if (!Array.isArray(value.actions) || !value.actions.every((item) => typeof item === "string" && allowedActions.has(item))) {
    throw usageError("capabilities.actions contains an unsupported value");
  }
  if (!Array.isArray(value.observations) || !value.observations.every((item) => typeof item === "string" && allowedObservations.has(item))) {
    throw usageError("capabilities.observations contains an unsupported value");
  }
  return {
    actions: [...new Set(value.actions)] as DriverCapabilities["actions"],
    observations: [...new Set(value.observations)] as DriverCapabilities["observations"]
  };
}

async function loadObject(path: string, label: string): Promise<Record<string, unknown>> {
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new CommandProtocolError("PARSE_ERROR", `Could not parse ${label} file ${path}`, {
      details: error instanceof Error ? error.message : String(error)
    });
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw usageError(`${label} file must contain a JSON object`);
  }
  return value as Record<string, unknown>;
}

async function emit(
  command: Awaited<ReturnType<typeof load>>,
  format: CommandFormat,
  outputPath: string | undefined,
  force: boolean
): Promise<void> {
  const serialized = serializeCommand(command, format);
  if (!outputPath || outputPath === "-") {
    stdout.write(serialized);
    return;
  }
  await writeFile(outputPath, serialized, { encoding: "utf8", flag: force ? "w" : "wx", mode: 0o600 });
  stdout.write(`Wrote ${outputPath}\n`);
}

function sourceFormat(path: string): SourceFormat {
  return [".yaml", ".yml"].includes(extname(path).toLocaleLowerCase()) ? "yaml" : "json";
}

function outputFormat(args: string[], fallback: CommandFormat): CommandFormat {
  const requested = option(args, "--format") ?? option(args, "--to");
  if (requested === undefined) {
    const output = option(args, "--output");
    return output && [".yaml", ".yml"].includes(extname(output).toLocaleLowerCase()) ? "yaml" : fallback;
  }
  if (requested !== "json" && requested !== "yaml") throw usageError("format must be json or yaml");
  return requested;
}

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw usageError(`${name} requires a value`);
  return value;
}

function flag(args: string[], name: string): boolean {
  return args.includes(name);
}

function positionals(args: string[]): string[] {
  const result: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (["--format", "--output", "--to", "--capabilities", "--library", "--inputs"].includes(value)) {
      index += 1;
    } else if (!value.startsWith("--")) {
      result.push(value);
    }
  }
  return result;
}

function usageError(message: string): CommandProtocolError {
  return new CommandProtocolError("PARSE_ERROR", `${message}\n\n${help}`);
}

main(process.argv.slice(2)).catch((error: unknown) => {
  if (error instanceof CommandProtocolError) {
    process.stderr.write(`${error.code}: ${error.message}\n`);
  } else if (error instanceof Error && "code" in error && error.code === "EEXIST") {
    process.stderr.write("Output file already exists; pass --force to replace it.\n");
  } else {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  }
  process.exitCode = 1;
});
