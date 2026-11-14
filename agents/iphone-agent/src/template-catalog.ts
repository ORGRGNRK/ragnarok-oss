import { readFile, realpath } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";

import { CommandProtocolError } from "./errors.js";
import { TemplateScreenResolver, type ScreenTemplate } from "./template-resolver.js";

export interface TemplateCompatibility {
  appVersion?: string;
  osVersion?: string;
  frameWidth?: number;
  frameHeight?: number;
}

export interface TemplateManifestEntry {
  label: string;
  file: string;
  mediaType: "image/jpeg";
  minimumConfidence?: number;
  compatibility?: TemplateCompatibility;
}

export interface TemplateManifest {
  schemaVersion: "0.1";
  threshold?: number;
  signatureWidth?: number;
  signatureHeight?: number;
  templates: TemplateManifestEntry[];
}

export interface TemplateCatalogOptions {
  compatibility?: TemplateCompatibility;
}

export class FileTemplateCatalog {
  private constructor(
    readonly manifestPath: string,
    readonly manifest: TemplateManifest,
    readonly templates: ScreenTemplate[],
    readonly resolver: TemplateScreenResolver
  ) {}

  static async load(manifestPath: string, options: TemplateCatalogOptions = {}): Promise<FileTemplateCatalog> {
    const canonicalManifest = await realpath(manifestPath);
    const base = await realpath(dirname(canonicalManifest));
    let manifest: TemplateManifest;
    try {
      manifest = parseManifest(JSON.parse(await readFile(canonicalManifest, "utf8")));
    } catch (error) {
      if (error instanceof CommandProtocolError) throw error;
      throw new CommandProtocolError("PARSE_ERROR", `Could not read template manifest ${manifestPath}`, {
        details: error instanceof Error ? error.message : String(error)
      });
    }

    const activeEntries = manifest.templates.filter((entry) => compatible(entry.compatibility, options.compatibility));
    const templates: ScreenTemplate[] = [];
    for (const entry of activeEntries) {
      const requested = resolveTemplatePath(base, entry.file);
      let canonicalFile: string;
      try {
        canonicalFile = await realpath(requested);
      } catch (error) {
        throw new CommandProtocolError("DRIVER_ERROR", `Template image does not exist: ${entry.file}`, {
          details: error instanceof Error ? error.message : String(error)
        });
      }
      assertWithin(base, canonicalFile, entry.file);
      templates.push({
        label: entry.label,
        minimumConfidence: entry.minimumConfidence,
        frame: {
          bytes: await readFile(canonicalFile),
          mediaType: entry.mediaType,
          reference: canonicalFile
        }
      });
    }

    const resolver = new TemplateScreenResolver(templates, {
      ...(manifest.threshold === undefined ? {} : { threshold: manifest.threshold }),
      ...(manifest.signatureWidth === undefined ? {} : { signatureWidth: manifest.signatureWidth }),
      ...(manifest.signatureHeight === undefined ? {} : { signatureHeight: manifest.signatureHeight })
    });
    return new FileTemplateCatalog(canonicalManifest, manifest, templates, resolver);
  }
}

function parseManifest(value: unknown): TemplateManifest {
  if (!isRecord(value) || value.schemaVersion !== "0.1" || !Array.isArray(value.templates)) {
    throw new CommandProtocolError("SCHEMA_INVALID", "Template manifest must use schemaVersion 0.1 and contain templates");
  }
  numberOption(value, "threshold", 0, 1);
  integerOption(value, "signatureWidth", 1);
  integerOption(value, "signatureHeight", 1);
  const templates = value.templates.map((entry, index) => parseEntry(entry, index));
  return {
    schemaVersion: "0.1",
    templates,
    ...(value.threshold === undefined ? {} : { threshold: value.threshold as number }),
    ...(value.signatureWidth === undefined ? {} : { signatureWidth: value.signatureWidth as number }),
    ...(value.signatureHeight === undefined ? {} : { signatureHeight: value.signatureHeight as number })
  };
}

function parseEntry(value: unknown, index: number): TemplateManifestEntry {
  if (!isRecord(value) || typeof value.label !== "string" || !value.label || typeof value.file !== "string" || !value.file) {
    throw new CommandProtocolError("SCHEMA_INVALID", `Template entry ${index} requires non-empty label and file`);
  }
  if (value.mediaType !== "image/jpeg") {
    throw new CommandProtocolError("SCHEMA_INVALID", `Template entry ${index} must use image/jpeg`);
  }
  numberOption(value, "minimumConfidence", 0, 1);
  const compatibility = parseCompatibility(value.compatibility, index);
  return {
    label: value.label,
    file: value.file,
    mediaType: "image/jpeg",
    ...(value.minimumConfidence === undefined ? {} : { minimumConfidence: value.minimumConfidence as number }),
    ...(compatibility ? { compatibility } : {})
  };
}

function parseCompatibility(value: unknown, index: number): TemplateCompatibility | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new CommandProtocolError("SCHEMA_INVALID", `Template entry ${index} compatibility must be an object`);
  const output: TemplateCompatibility = {};
  for (const key of ["appVersion", "osVersion"] as const) {
    if (value[key] !== undefined && (typeof value[key] !== "string" || !value[key])) {
      throw new CommandProtocolError("SCHEMA_INVALID", `Template entry ${index} compatibility.${key} must be a string`);
    }
    if (typeof value[key] === "string") output[key] = value[key];
  }
  for (const key of ["frameWidth", "frameHeight"] as const) {
    integerOption(value, key, 1);
    if (typeof value[key] === "number") output[key] = value[key];
  }
  return output;
}

function resolveTemplatePath(base: string, file: string): string {
  if (isAbsolute(file)) {
    throw new CommandProtocolError("SCHEMA_INVALID", `Template paths must be relative: ${file}`);
  }
  const candidate = resolve(base, file);
  assertWithin(base, candidate, file);
  return candidate;
}

function assertWithin(base: string, candidate: string, source: string): void {
  const offset = relative(base, candidate);
  if (offset === ".." || offset.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || isAbsolute(offset)) {
    throw new CommandProtocolError("SCHEMA_INVALID", `Template path escapes its manifest directory: ${source}`);
  }
}

function compatible(required: TemplateCompatibility | undefined, actual: TemplateCompatibility | undefined): boolean {
  if (!required || !actual) return true;
  return (Object.keys(required) as Array<keyof TemplateCompatibility>).every(
    (key) => actual[key] === undefined || actual[key] === required[key]
  );
}

function numberOption(value: Record<string, unknown>, key: string, minimum: number, maximum: number): void {
  const item = value[key];
  if (item !== undefined && (typeof item !== "number" || !Number.isFinite(item) || item < minimum || item > maximum)) {
    throw new CommandProtocolError("SCHEMA_INVALID", `${key} must be between ${minimum} and ${maximum}`);
  }
}

function integerOption(value: Record<string, unknown>, key: string, minimum: number): void {
  const item = value[key];
  if (item !== undefined && (typeof item !== "number" || !Number.isInteger(item) || item < minimum)) {
    throw new CommandProtocolError("SCHEMA_INVALID", `${key} must be an integer of at least ${minimum}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
