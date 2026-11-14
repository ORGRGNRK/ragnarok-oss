import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { promisify } from "node:util";

import { CommandProtocolError } from "./errors.js";
import type { MirrorHostState, MirrorObservationResolver, ResolvedTarget } from "./runtime-types.js";
import type { ObservationCapability } from "./types.js";
import type { AppTarget, PortableTarget } from "./types.js";

const executeFile = promisify(execFile);

export class MacOsVisionTextResolver implements MirrorObservationResolver {
  readonly capabilities: ObservationCapability[] = ["screenshot", "screenText", "app", "target"];
  private executable?: Promise<string>;

  async observe(state: MirrorHostState): Promise<{
    screenText: string[];
    app?: AppTarget;
    screenshotRef?: string;
    captureScale?: number;
    metadata: Record<string, unknown>;
  }> {
    if (!state.frame?.reference) {
      throw new CommandProtocolError("DRIVER_ERROR", "The macOS text resolver needs a captured mirror frame");
    }
    const executable = await (this.executable ??= this.compile());
    try {
      const result = await executeFile(executable, [state.frame.reference], {
        maxBuffer: 2 * 1024 * 1024,
        timeout: 20_000,
        killSignal: "SIGKILL"
      });
      const recognized = parseRecognizedText(result.stdout);
      const screenText = recognized.map((item) => item.text);
      const app = inferVisibleApp(screenText);
      return {
        screenText,
        ...(app ? { app } : {}),
        screenshotRef: state.frame.reference,
        ...(state.frame.scale === undefined ? {} : { captureScale: state.frame.scale }),
        metadata: {
          observationStrategy: "macOS Vision OCR",
          recognizedLineCount: screenText.length,
          recognizedText: recognized
        }
      };
    } catch (error) {
      throw new CommandProtocolError("DRIVER_ERROR", "macOS could not read text from the mirrored screen", {
        details: error instanceof Error ? error.message : String(error)
      });
    }
  }

  async resolveTarget(state: MirrorHostState, target: PortableTarget): Promise<ResolvedTarget | undefined> {
    if (!state.frame?.reference) return undefined;
    const executable = await (this.executable ??= this.compile());
    try {
      const result = await executeFile(executable, [state.frame.reference], {
        maxBuffer: 2 * 1024 * 1024,
        timeout: 20_000,
        killSignal: "SIGKILL"
      });
      return resolveRecognizedTarget(parseRecognizedText(result.stdout), target);
    } catch (error) {
      throw new CommandProtocolError("DRIVER_ERROR", "macOS could not locate text on the mirrored screen", {
        details: error instanceof Error ? error.message : String(error)
      });
    }
  }

  private async compile(): Promise<string> {
    if (process.platform !== "darwin") {
      throw new CommandProtocolError("DRIVER_ERROR", "macOS Vision OCR requires macOS");
    }
    const directory = await mkdtemp(join(tmpdir(), "iphone-command-vision-"));
    const executable = join(directory, "vision-ocr");
    const source = fileURLToPath(new URL("../native/vision-ocr.swift", import.meta.url));
    try {
      await executeFile("/usr/bin/swiftc", [source, "-o", executable], { maxBuffer: 2 * 1024 * 1024 });
    } catch (error) {
      throw new CommandProtocolError("DRIVER_ERROR", "Could not prepare macOS Vision text recognition", {
        details: error instanceof Error ? error.message : String(error)
      });
    }
    return executable;
  }
}

export interface RecognizedText {
  text: string;
  confidence: number;
  x: number;
  y: number;
  width: number;
  height: number;
}

export function parseRecognizedText(output: string): RecognizedText[] {
  const parsed = JSON.parse(output) as unknown;
  if (!Array.isArray(parsed)) throw new Error("Vision OCR returned an unexpected result");
  return parsed.filter(isRecognizedText);
}

export function resolveRecognizedTarget(
  recognized: RecognizedText[],
  target: PortableTarget
): ResolvedTarget | undefined {
  const clues = [target.text, target.label, target.hint].filter((value): value is string => Boolean(value));
  if (clues.length === 0) return undefined;

  const normalizedClues = clues.map(normalizeText);
  const ranked = recognized.flatMap((item) => {
    const normalizedText = normalizeText(item.text);
    const exact = normalizedClues.some((clue) => normalizedText === clue);
    const partial = normalizedClues.some((clue) => normalizedText.includes(clue) || clue.includes(normalizedText));
    if (!exact && !partial) return [];
    return [{
      item,
      exact,
      score: exact ? 0.9 + Math.max(0, item.confidence) * 0.09 : 0.6 + Math.max(0, item.confidence) * 0.09
    }];
  }).sort((left, right) => right.score - left.score || right.item.y - left.item.y);

  const match = ranked[0];
  if (!match) return undefined;
  return {
    strategy: "macOS Vision text",
    confidence: Math.min(0.99, match.score),
    point: {
      x: match.item.x + match.item.width / 2,
      y: 1 - (match.item.y + match.item.height / 2)
    },
    clue: match.item.text
  };
}

function isRecognizedText(value: unknown): value is RecognizedText {
  if (!value || typeof value !== "object") return false;
  const item = value as Record<string, unknown>;
  return typeof item.text === "string" && ["confidence", "x", "y", "width", "height"].every(
    (key) => typeof item[key] === "number" && Number.isFinite(item[key])
  );
}

function normalizeText(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

export function inferVisibleApp(screenText: string[]): AppTarget | undefined {
  const normalized = screenText.map((line) => line.toLocaleLowerCase());
  const settingsClues = [
    "settings",
    "general",
    "about",
    "ios version",
    "model name",
    "model number",
    "serial number",
    "coverage",
    "background app refresh",
    "date & time",
    "language & region",
    "vpn & device management",
    "transfer or reset iphone",
    "privacy & security",
    "sounds & haptics",
    "screen time",
    "apple account",
    "airplane mode",
    "battery health",
    "maximum capacity",
    "cycle count",
    "manufacture date",
    "first use"
  ];
  const matches = settingsClues.filter((clue) => normalized.some((line) => line.includes(clue)));
  return matches.length >= 2
    ? { name: "Settings", bundleId: "com.apple.Preferences" }
    : undefined;
}
