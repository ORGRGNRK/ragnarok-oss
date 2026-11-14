import { readdir, readFile } from "node:fs/promises";
import { extname, join } from "node:path";

import { maxSatisfying, rcompare, satisfies } from "semver";

import { CommandProtocolError } from "./errors.js";
import type { CommandRegistry } from "./runtime-types.js";
import type { CommandDocument } from "./types.js";
import { parseCommand, validateCommand } from "./validator.js";

export class InMemoryCommandRegistry implements CommandRegistry {
  private readonly commands = new Map<string, CommandDocument[]>();

  constructor(commands: CommandDocument[] = []) {
    for (const command of commands) this.add(command);
  }

  add(command: CommandDocument): void {
    validateCommand(command);
    const versions = this.commands.get(command.id) ?? [];
    const withoutSameVersion = versions.filter((candidate) => candidate.version !== command.version);
    withoutSameVersion.push(structuredClone(command));
    withoutSameVersion.sort((left, right) => rcompare(left.version, right.version));
    this.commands.set(command.id, withoutSameVersion);
  }

  remove(commandId: string): void {
    this.commands.delete(commandId);
  }

  async get(commandId: string, versionRange = "*"): Promise<CommandDocument | undefined> {
    const versions = this.commands.get(commandId) ?? [];
    const selectedVersion = maxSatisfying(versions.map((command) => command.version), versionRange);
    const selected = versions.find((command) => command.version === selectedVersion);
    return selected ? structuredClone(selected) : undefined;
  }
}

export class DirectoryCommandRegistry implements CommandRegistry {
  private loaded?: Promise<InMemoryCommandRegistry>;

  constructor(private readonly directory: string) {}

  async get(commandId: string, versionRange?: string): Promise<CommandDocument | undefined> {
    this.loaded ??= this.load();
    return (await this.loaded).get(commandId, versionRange);
  }

  private async load(): Promise<InMemoryCommandRegistry> {
    const registry = new InMemoryCommandRegistry();
    for (const path of await commandFiles(this.directory)) {
      const format = [".yaml", ".yml"].includes(extname(path).toLocaleLowerCase()) ? "yaml" : "json";
      registry.add(parseCommand(await readFile(path, "utf8"), format));
    }
    return registry;
  }
}

export function assertCommandVersion(command: CommandDocument, versionRange: string, path?: string): void {
  if (!satisfies(command.version, versionRange)) {
    throw new CommandProtocolError(
      "INCOMPATIBLE_VERSION",
      `Command ${command.id}@${command.version} does not satisfy ${versionRange}`,
      { path }
    );
  }
}

async function commandFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.name.startsWith(".")) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await commandFiles(path)));
    } else if ([".json", ".yaml", ".yml"].includes(extname(entry.name).toLocaleLowerCase())) {
      files.push(path);
    }
  }
  return files;
}
