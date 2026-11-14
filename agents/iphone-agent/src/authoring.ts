import { stringify } from "yaml";

import { CommandProtocolError } from "./errors.js";
import { assessSafety } from "./policy.js";
import type { CommandDocument, RiskClass } from "./types.js";
import { normalizeCommand, validateCommand } from "./validator.js";

export type CommandFormat = "json" | "yaml";

export interface NaturalLanguageAuthorRequest {
  text: string;
  schemaVersion: "0.1";
}

export interface NaturalLanguageDraftProvider {
  generate(request: NaturalLanguageAuthorRequest): Promise<unknown>;
}

export class ValidatingNaturalLanguageAuthor {
  constructor(private readonly provider: NaturalLanguageDraftProvider) {}

  async author(text: string): Promise<CommandDocument> {
    const trimmed = text.trim();
    if (!trimmed) {
      throw new CommandProtocolError("PARSE_ERROR", "Natural-language command text cannot be empty");
    }
    const proposed = await this.provider.generate({ text: trimmed, schemaVersion: "0.1" });
    const normalized = normalizeCommand(proposed);
    validateCommand(normalized);
    // Run policy classification now so a provider cannot make an invalid risk declaration
    // disappear merely by setting requiresConfirmation to false.
    assessSafety(normalized);
    return normalized;
  }
}

export class RuleBasedNaturalLanguageProvider implements NaturalLanguageDraftProvider {
  async generate(request: NaturalLanguageAuthorRequest): Promise<unknown> {
    const text = request.text.trim();

    // Matched before the plain open pattern so the trailing check phrase is not absorbed
    // into the app name. The mirror verifies through recognized screen text, so an author
    // who names the text they expect gets a command that can actually prove it worked.
    const openAndCheck = text.match(
      /^open\s+(?:the\s+)?(.+?)(?:\s+app)?\s+(?:and|then)\s+(?:check|verify|confirm)\s+(?:for\s+|that\s+)?["\u201c]?(.+?)["\u201d]?(?:\s+is\s+visible)?[.!]?$/i
    );
    if (openAndCheck) {
      const appName = cleanPhrase(openAndCheck[1]);
      const screenText = cleanPhrase(openAndCheck[2]);
      return baseCommand(text, `open-${slug(appName)}`, `Open ${appName}`, "reversible", [
        {
          id: `open-${slug(appName)}`,
          action: "openApp",
          app: { name: appName },
          expect: { screenText }
        }
      ], [{ screenText }]);
    }

    const open = text.match(/^open\s+(?:the\s+)?(.+?)(?:\s+app)?[.!]?$/i);
    if (open) {
      const appName = cleanPhrase(open[1]);
      return baseCommand(text, `open-${slug(appName)}`, `Open ${appName}`, "reversible", [
        {
          id: `open-${slug(appName)}`,
          action: "openApp",
          app: { name: appName },
          expect: { screenText: appName }
        }
      ], [{ screenText: appName }]);
    }

    const press = text.match(/^press\s+(home|app\s*switcher|back)[.!]?$/i);
    if (press) {
      const button = normalizeButton(press[1]);
      return baseCommand(text, `press-${slug(button)}`, `Press ${humanize(button)}`, "reversible", [
        { id: `press-${slug(button)}`, action: "press", button }
      ]);
    }

    const swipe = text.match(/^swipe\s+(up|down|left|right)[.!]?$/i);
    if (swipe) {
      const direction = swipe[1].toLocaleLowerCase();
      return baseCommand(text, `swipe-${direction}`, `Swipe ${direction}`, "reversible", [
        { id: `swipe-${direction}`, action: "swipe", direction }
      ]);
    }

    const wait = text.match(/^wait\s+(?:for\s+)?(?:text\s+)?["“]?(.+?)["”]?[.!]?$/i);
    if (wait) {
      const screenText = cleanPhrase(wait[1]);
      return baseCommand(text, `wait-for-${slug(screenText)}`, `Wait for ${screenText}`, "read", [
        { id: `wait-for-${slug(screenText)}`, action: "waitFor", condition: { screenText } }
      ], [{ screenText }]);
    }

    const assertion = text.match(/^assert\s+(?:that\s+)?(?:text\s+)?["“]?(.+?)["”]?(?:\s+is\s+visible)?[.!]?$/i);
    if (assertion) {
      const screenText = cleanPhrase(assertion[1]);
      return baseCommand(text, `assert-${slug(screenText)}`, `Assert ${screenText}`, "read", [
        { id: `assert-${slug(screenText)}`, action: "assert", condition: { screenText } }
      ], [{ screenText }]);
    }

    throw new CommandProtocolError(
      "PARSE_ERROR",
      "The built-in author understands: open <app>, open <app> and check for <text>, press <home|app switcher|back>, swipe <direction>, wait for <text>, and assert <text>. Use guided creation for anything else."
    );
  }
}

export function serializeCommand(command: CommandDocument, format: CommandFormat): string {
  validateCommand(command);
  if (format === "json") return `${JSON.stringify(command, null, 2)}\n`;
  return stringify(command, { lineWidth: 0, sortMapEntries: false });
}

function baseCommand(
  sourceText: string,
  idSuffix: string,
  name: string,
  risk: RiskClass,
  steps: unknown[],
  postconditions: unknown[] = []
): unknown {
  return {
    schemaVersion: "0.1",
    id: `com.yggdrasil.iphone.${idSuffix}`,
    name,
    description: `Authored from: ${sourceText}`,
    safety: { risk },
    steps,
    postconditions
  };
}

function cleanPhrase(value: string): string {
  return value.trim().replace(/[.!]+$/, "").trim();
}

function slug(value: string): string {
  const result = value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  return result || "command";
}

function normalizeButton(value: string): "home" | "appSwitcher" | "back" {
  return value.replace(/\s+/g, "").toLocaleLowerCase() === "appswitcher" ? "appSwitcher" : value.toLocaleLowerCase() as "home" | "back";
}

function humanize(value: string): string {
  return value === "appSwitcher" ? "App Switcher" : `${value[0]?.toLocaleUpperCase()}${value.slice(1)}`;
}
