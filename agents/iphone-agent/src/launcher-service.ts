import { readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { extname, join, resolve, sep } from "node:path";

import { RuleBasedNaturalLanguageProvider, ValidatingNaturalLanguageAuthor, serializeCommand } from "./authoring.js";
import { InMemoryCommandRegistry } from "./catalog.js";
import { describeStep } from "./describe.js";
import { dryRunCommand, type DryRunReport } from "./dry-run.js";
import { CommandProtocolError } from "./errors.js";
import { IPhoneMirroringDriver } from "./mirror-driver.js";
import { MacOsMirrorControlPort } from "./macos-mirror-port.js";
import { MacOsVisionTextResolver } from "./macos-vision-resolver.js";
import { assessSafety, isAtMostRisk } from "./policy.js";
import { DeterministicRunner } from "./runner.js";
import type {
  ConfirmationProvider,
  DriverActionResult,
  DriverObservation,
  DriverSession,
  DriverStep,
  ExecutionReceipt,
  PortableDriver
} from "./runtime-types.js";
import type { ScreenshotArtifactSink } from "./runtime-types.js";
import type { ActionName, CommandDocument, RiskClass } from "./types.js";
import type { DriverCapabilities } from "./types.js";
import { parseCommand } from "./validator.js";

export interface LauncherCommand {
  id: string;
  name: string;
  description: string;
  version: string;
  risk: RiskClass;
  requiresConfirmation: boolean;
  enabled: boolean;
  manageable: boolean;
  sourceText?: string;
  unavailableReason?: string;
}

export interface AuthorStepSummary {
  stepId: string;
  action: ActionName;
  plain: string;
}

export interface AuthorProposal {
  text: string;
  command: {
    id: string;
    name: string;
    description: string;
    version: string;
    risk: RiskClass;
  };
  steps: AuthorStepSummary[];
  supported: boolean;
  saveable: boolean;
  blockedReason?: string;
  actionsExecuted: 0;
}

export interface LauncherStatus {
  mode: "live" | "demo";
  platform: string;
  commands: LauncherCommand[];
  busy: boolean;
}

export interface LauncherServiceOptions {
  commands: CommandDocument[];
  driverFactory: () => Promise<PortableDriver>;
  mode?: "live" | "demo";
  capabilities?: DriverCapabilities;
  /** Saving authored commands stays disabled unless a writable directory is supplied. */
  commandsDirectory?: string;
  /**
   * Without a provider the launcher runs only commands that never need a human answer. Supplying
   * one raises the ceiling to `external`; see {@link runnableCeiling}.
   */
  confirmationProvider?: ConfirmationProvider;
  screenshotArtifactSink?: ScreenshotArtifactSink;
}

export class LauncherService {
  private readonly commands: Map<string, CommandDocument>;
  private readonly registry: InMemoryCommandRegistry;
  private busy = false;

  constructor(private readonly options: LauncherServiceOptions) {
    this.commands = new Map(options.commands.map((command) => [command.id, command]));
    this.registry = new InMemoryCommandRegistry(options.commands);
  }

  status(): LauncherStatus {
    return {
      mode: this.options.mode ?? "live",
      platform: process.platform,
      commands: [...this.commands.values()].map((command) => toLauncherCommand(command, this.ceiling())),
      busy: this.busy
    };
  }

  /**
   * The highest risk this launcher will run. A confirmation provider is what makes `external`
   * runnable at all; `financial`, `destructive`, and `credential` stay blocked regardless,
   * because each deserves its own decision rather than arriving as a side effect of this one.
   */
  private ceiling(): RiskClass {
    return this.options.confirmationProvider ? runnableCeiling : "reversible";
  }

  /** The interface hides the authoring panel entirely when saving is not configured. */
  canAuthor(): boolean {
    return typeof this.options.commandsDirectory === "string" && this.options.commandsDirectory.length > 0;
  }

  async dryRun(commandId: string): Promise<DryRunReport> {
    const command = this.getRunnableCommand(commandId);
    return dryRunCommand(command, {}, {
      capabilities: this.options.capabilities ?? liveCapabilities,
      registry: this.registry
    });
  }

  async run(commandId: string): Promise<ExecutionReceipt> {
    if (this.busy) throw new CommandProtocolError("DRIVER_ERROR", "Another iPhone command is already running");
    const command = this.getRunnableCommand(commandId);
    const preflight = await this.dryRun(commandId);
    if (!preflight.supported) {
      throw new CommandProtocolError("UNSUPPORTED_CAPABILITY", "This command is not ready for the local launcher", {
        details: preflight
      });
    }
    if (preflight.confirmationPaths.length > 0 && !this.options.confirmationProvider) {
      throw new CommandProtocolError(
        "CONFIRMATION_UNAVAILABLE",
        "This command needs confirmation during execution and is not enabled in the launcher yet",
        { details: { confirmationPaths: preflight.confirmationPaths } }
      );
    }

    this.busy = true;
    try {
      const driver = await this.options.driverFactory();
      const runner = new DeterministicRunner(driver, {
        commandRegistry: this.registry,
        idFactory: () => `launcher-${Date.now()}`,
        ...(this.options.screenshotArtifactSink ? { screenshotArtifactSink: this.options.screenshotArtifactSink } : {}),
        ...(this.options.confirmationProvider ? { confirmationProvider: this.options.confirmationProvider } : {})
      });
      return await runner.run({ command });
    } finally {
      this.busy = false;
    }
  }

  /**
   * Turn plain language into a proposed command without saving it and without touching the
   * phone. The draft passes through the same validator, safety policy, and recursive
   * preflight that a saved command would, so the interface can only ever offer Save for a
   * command the launcher could actually run.
   */
  async author(text: string, replacingCommandId?: string): Promise<AuthorProposal> {
    if (replacingCommandId !== undefined) this.getManageableCommand(replacingCommandId);
    const command = await this.authorDraft(text);
    const preflight = await dryRunCommand(command, {}, {
      capabilities: this.options.capabilities ?? liveCapabilities,
      registry: this.registry
    });
    const blockedReason = this.saveBlockedReason(command, preflight, replacingCommandId);
    return {
      text,
      command: {
        id: command.id,
        name: command.name,
        description: command.description ?? friendlyDescription(command),
        version: command.version,
        risk: command.safety.risk
      },
      steps: command.steps.map((step) => ({
        stepId: step.id,
        action: step.action,
        plain: describeStep(step)
      })),
      supported: preflight.supported,
      saveable: blockedReason === undefined,
      ...(blockedReason === undefined ? {} : { blockedReason }),
      actionsExecuted: 0
    };
  }

  /**
   * Re-author from the same text rather than accepting a command document from the
   * interface. The built-in provider is deterministic, so this saves exactly what was
   * shown while keeping the browser unable to submit an arbitrary document.
   */
  async save(text: string): Promise<LauncherCommand> {
    const directory = this.options.commandsDirectory;
    if (!directory) {
      throw new CommandProtocolError("DRIVER_ERROR", "This launcher is not configured to save new commands");
    }
    const command = await this.authorDraft(text);
    const preflight = await dryRunCommand(command, {}, {
      capabilities: this.options.capabilities ?? liveCapabilities,
      registry: this.registry
    });
    const blockedReason = this.saveBlockedReason(command, preflight);
    if (blockedReason !== undefined) {
      throw new CommandProtocolError("UNSUPPORTED_CAPABILITY", blockedReason, { details: preflight });
    }

    const path = commandFilePath(directory, command.id);
    // wx refuses to clobber a file the in-memory catalog does not know about.
    await writeFile(path, serializeCommand(command, "json"), { encoding: "utf8", mode: 0o600, flag: "wx" });
    this.commands.set(command.id, command);
    this.registry.add(command);
    return toLauncherCommand(command, this.ceiling());
  }

  /** Re-author and replace a launcher-created command without accepting a browser document. */
  async update(commandId: string, text: string): Promise<LauncherCommand> {
    const directory = this.options.commandsDirectory;
    if (!directory) {
      throw new CommandProtocolError("DRIVER_ERROR", "This launcher is not configured to edit saved commands");
    }
    this.getManageableCommand(commandId);
    const command = await this.authorDraft(text);
    const preflight = await dryRunCommand(command, {}, {
      capabilities: this.options.capabilities ?? liveCapabilities,
      registry: this.registry
    });
    const blockedReason = this.saveBlockedReason(command, preflight, commandId);
    if (blockedReason !== undefined) {
      throw new CommandProtocolError("UNSUPPORTED_CAPABILITY", blockedReason, { details: preflight });
    }

    const path = commandFilePath(directory, commandId);
    await this.assertManagedFile(path, commandId);
    await writeFile(path, serializeCommand(command, "json"), { encoding: "utf8", mode: 0o600, flag: "w" });
    this.commands.set(command.id, command);
    this.registry.add(command);
    return toLauncherCommand(command, this.ceiling());
  }

  /** Delete only a launcher-created command whose exact backing file still matches its id. */
  async delete(commandId: string): Promise<void> {
    const directory = this.options.commandsDirectory;
    if (!directory) {
      throw new CommandProtocolError("DRIVER_ERROR", "This launcher is not configured to delete saved commands");
    }
    this.getManageableCommand(commandId);
    const path = commandFilePath(directory, commandId);
    await this.assertManagedFile(path, commandId);
    await unlink(path);
    this.commands.delete(commandId);
    this.registry.remove(commandId);
  }

  private async authorDraft(text: string): Promise<CommandDocument> {
    if (typeof text !== "string" || text.trim().length === 0) {
      throw new CommandProtocolError("PARSE_ERROR", "Describe the routine you want in a few words");
    }
    if (text.length > 500) {
      throw new CommandProtocolError("PARSE_ERROR", "Keep the description short and specific");
    }
    return new ValidatingNaturalLanguageAuthor(new RuleBasedNaturalLanguageProvider()).author(text);
  }

  private saveBlockedReason(
    command: CommandDocument,
    preflight: DryRunReport,
    replacingCommandId?: string
  ): string | undefined {
    if (!this.options.commandsDirectory) return "This launcher is not configured to save new commands";
    if (replacingCommandId !== undefined && command.id !== replacingCommandId) {
      return "An edit cannot change which saved command this is. Create a new command instead.";
    }
    if (this.commands.has(command.id) && command.id !== replacingCommandId) {
      return `A saved command already uses the name ${command.name}`;
    }
    if (!isAtMostRisk(assessSafety(command).risk, this.ceiling())) {
      return unavailableReason(this.ceiling());
    }
    if (preflight.confirmationPaths.length > 0 && !this.options.confirmationProvider) {
      return "This routine would need confirmation while it runs, which the launcher cannot do yet";
    }
    if (!preflight.supported) {
      const missing = preflight.missingCapabilities.map((entry) => entry.capability).join(", ");
      return `The launcher cannot do this yet${missing ? `: ${missing}` : ""}`;
    }
    return undefined;
  }

  private getManageableCommand(commandId: string): CommandDocument {
    const command = this.commands.get(commandId);
    if (!command) throw new CommandProtocolError("COMMAND_NOT_FOUND", `Launcher command ${commandId} was not found`);
    if (authorSourceText(command) === undefined) {
      throw new CommandProtocolError("UNSUPPORTED_CAPABILITY", `${command.name} is a built-in command and cannot be changed`);
    }
    return command;
  }

  private async assertManagedFile(path: string, commandId: string): Promise<void> {
    const persisted = parseCommand(await readFile(path, "utf8"), extname(path) === ".json" ? "json" : "yaml");
    if (persisted.id !== commandId || authorSourceText(persisted) === undefined) {
      throw new CommandProtocolError("SCHEMA_INVALID", "The saved command changed on disk; refresh before trying again");
    }
  }

  private getRunnableCommand(commandId: string): CommandDocument {
    const command = this.commands.get(commandId);
    if (!command) throw new CommandProtocolError("COMMAND_NOT_FOUND", `Launcher command ${commandId} was not found`);
    if (!isAtMostRisk(assessSafety(command).risk, this.ceiling())) {
      throw new CommandProtocolError("CONFIRMATION_UNAVAILABLE", unavailableReason(this.ceiling()));
    }
    return command;
  }
}

export async function loadLauncherCommands(directory: string): Promise<CommandDocument[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const commands: CommandDocument[] = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isFile() || ![".json", ".yaml", ".yml"].includes(extname(entry.name).toLocaleLowerCase())) continue;
    const path = join(directory, entry.name);
    commands.push(parseCommand(await readFile(path, "utf8"), [".yaml", ".yml"].includes(extname(path)) ? "yaml" : "json"));
  }
  return commands;
}

export async function createLiveDriver(): Promise<PortableDriver> {
  const port = new MacOsMirrorControlPort();
  await port.focus();
  const bounds = await port.getWindowBounds();
  return new IPhoneMirroringDriver({
    port,
    resolver: new MacOsVisionTextResolver(),
    actionBounds: bounds,
    actions: [...liveCapabilities.actions]
  });
}

export function createDemoDriver(): PortableDriver {
  return new DemoIPhoneDriver();
}

export const liveCapabilities: DriverCapabilities = {
  actions: ["openApp", "tap", "typeText", "swipe", "press"],
  observations: ["screenshot", "screenText", "app", "target"]
};

class DemoIPhoneDriver implements PortableDriver {
  private screenText = ["Home"];
  private app: DriverObservation["app"];

  async startSession(): Promise<DriverSession> {
    return { id: "launcher-demo", version: "0.1", capabilities: liveCapabilities };
  }

  async observe(): Promise<DriverObservation> {
    return {
      capturedAt: new Date().toISOString(),
      screenText: [...this.screenText],
      ...(this.app ? { app: this.app } : {}),
      screenshotRef: "demo://frame"
    };
  }

  async execute(step: DriverStep): Promise<DriverActionResult> {
    if (step.action === "openApp") {
      this.screenText = [step.app.name ?? step.app.bundleId ?? "App"];
      this.app = structuredClone(step.app);
    }
    if (step.action === "press" && step.button === "home") {
      this.screenText = ["Home"];
      this.app = undefined;
    }
    return {};
  }
}

/**
 * Cards report the assessed risk, not the declared one. A command whose steps individually
 * reach higher than its own header must not present itself as the safer number.
 */
function toLauncherCommand(command: CommandDocument, ceiling: RiskClass): LauncherCommand {
  const safety = assessSafety(command);
  const enabled = isAtMostRisk(safety.risk, ceiling);
  const sourceText = authorSourceText(command);
  return {
    id: command.id,
    name: command.name,
    description: command.description ?? friendlyDescription(command),
    version: command.version,
    risk: safety.risk,
    requiresConfirmation: safety.requiresConfirmation,
    enabled,
    manageable: sourceText !== undefined,
    ...(sourceText === undefined ? {} : { sourceText }),
    ...(enabled ? {} : { unavailableReason: unavailableReason(ceiling) })
  };
}

function authorSourceText(command: CommandDocument): string | undefined {
  const prefix = "Authored from: ";
  return command.description?.startsWith(prefix) ? command.description.slice(prefix.length) : undefined;
}

function friendlyDescription(command: CommandDocument): string {
  const first = command.steps[0];
  if (first?.action === "openApp") return `Open ${first.app.name ?? "an app"} on your mirrored iPhone.`;
  return `${command.steps.length} safe iPhone step${command.steps.length === 1 ? "" : "s"}.`;
}

/**
 * The ceiling a confirmation provider unlocks. Raising it past `external` is a separate
 * decision, not a consequence of this one.
 */
const runnableCeiling: RiskClass = "external";

function unavailableReason(ceiling: RiskClass): string {
  return ceiling === "reversible"
    ? "Committing commands stay disabled until the launcher can confirm immediately before their final action"
    : "Commands that move money, destroy data, or use credentials stay disabled in the launcher";
}

/**
 * Saved files are named from the command id's final segment only, and the resolved path is
 * required to stay directly inside the launcher command folder.
 */
function commandFilePath(directory: string, commandId: string): string {
  const segment = commandId.split(".").pop() ?? "";
  if (!/^[a-z0-9][a-z0-9-]*$/.test(segment)) {
    throw new CommandProtocolError("PARSE_ERROR", "That routine cannot be saved under a safe file name");
  }
  const root = resolve(directory);
  const path = resolve(root, `${segment}.json`);
  if (path !== join(root, `${segment}.json`) || !path.startsWith(root + sep)) {
    throw new CommandProtocolError("PARSE_ERROR", "Refusing to write outside the launcher command folder");
  }
  return path;
}
