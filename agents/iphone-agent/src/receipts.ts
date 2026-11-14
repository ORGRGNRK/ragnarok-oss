import { chmod, copyFile, mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, extname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

import { CommandProtocolError } from "./errors.js";
import type {
  ExecutionArtifact,
  ExecutionReceipt,
  ReceiptSink,
  ScreenshotArtifactRequest,
  ScreenshotArtifactSink
} from "./runtime-types.js";
import { validateReceipt } from "./validator.js";

export class MemoryReceiptSink implements ReceiptSink {
  readonly snapshots: ExecutionReceipt[] = [];

  async write(receipt: ExecutionReceipt): Promise<void> {
    validateReceipt(receipt);
    this.snapshots.push(structuredClone(receipt));
  }
}

export class JsonFileReceiptSink implements ReceiptSink {
  constructor(private readonly path: string) {}

  async write(receipt: ExecutionReceipt): Promise<void> {
    validateReceipt(receipt);
    await mkdir(dirname(this.path), { recursive: true });
    const temporaryPath = `${this.path}.tmp-${process.pid}-${Date.now()}`;
    await writeFile(temporaryPath, `${JSON.stringify(receipt, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    await rename(temporaryPath, this.path);
  }
}

/** Copies temporary mirror frames into a private, user-visible evidence directory. */
export class LocalScreenshotArtifactSink implements ScreenshotArtifactSink {
  constructor(private readonly directory: string) {}

  async writeScreenshot(request: ScreenshotArtifactRequest): Promise<ExecutionArtifact> {
    const source = localPath(request.observation.screenshotRef);
    const runDirectory = join(this.directory, safeSegment(request.receiptId));
    const suffix = extname(source).toLocaleLowerCase() === ".jpg" ? ".jpg" : ".png";
    const destination = join(
      runDirectory,
      `${safeSegment(request.stepId)}-${safeSegment(request.label)}${suffix}`
    );
    await mkdir(runDirectory, { recursive: true, mode: 0o700 });
    await copyFile(source, destination);
    await chmod(destination, 0o600);
    return {
      kind: "screenshot",
      reference: destination,
      mediaType: suffix === ".jpg" ? "image/jpeg" : "image/png"
    };
  }
}

function localPath(reference: string | undefined): string {
  if (!reference) {
    throw new CommandProtocolError("DRIVER_ERROR", "The screenshot observation did not include a file reference");
  }
  if (reference.startsWith("file://")) return fileURLToPath(reference);
  if (isAbsolute(reference)) return reference;
  throw new CommandProtocolError("DRIVER_ERROR", "The local artifact store requires a file-backed screenshot");
}

function safeSegment(value: string): string {
  const safe = value.trim().replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  if (!safe || safe === "." || safe === "..") return "capture";
  return safe.slice(0, 160);
}
