import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { CommandProtocolError } from "./errors.js";
import type { MirrorActionBounds, MirrorControlPort, MirrorHostState } from "./runtime-types.js";

const executeFile = promisify(execFile);

export interface MacOsMirrorControlPortOptions {
  settleMs?: number;
  captureFrames?: boolean;
}

export class MacOsMirrorControlPort implements MirrorControlPort {
  private readonly settleMs: number;
  private readonly captureFrames: boolean;
  private frameDirectory?: string;
  private lastFrame?: string;
  private clickExecutable?: Promise<string>;
  private swipeExecutable?: Promise<string>;

  constructor(options: MacOsMirrorControlPortOptions = {}) {
    this.settleMs = options.settleMs ?? 650;
    this.captureFrames = options.captureFrames ?? true;
  }

  async focus(): Promise<void> {
    this.assertMacOs();
    await this.appleScript([
      'tell application "iPhone Mirroring" to activate',
      'tell application "System Events"',
      '  if not (exists process "iPhone Mirroring") then error "iPhone Mirroring did not launch"',
      '  tell process "iPhone Mirroring" to set frontmost to true',
      'end tell'
    ].join("\n"));
    await wait(this.settleMs);
  }

  async getState(): Promise<MirrorHostState> {
    this.assertMacOs();
    await wait(this.settleMs);
    const accessibilityText = await this.accessibilitySnapshot();
    if (!this.captureFrames) return { accessibilityText };

    const bounds = await this.getWindowBounds();
    const framePath = await this.capture(bounds);
    const bytes = await readFile(framePath);
    const scale = captureScale(bytes, bounds);
    return {
      accessibilityText,
      frame: {
        bytes,
        mediaType: "image/png",
        reference: framePath,
        ...(scale === undefined ? {} : { scale })
      }
    };
  }

  async getWindowBounds(): Promise<MirrorActionBounds> {
    const output = await this.appleScript([
      'tell application "System Events"',
      '  tell process "iPhone Mirroring"',
      '    if not (exists front window) then error "No iPhone Mirroring window is open"',
      '    set windowPosition to position of front window',
      '    set windowSize to size of front window',
      '    return (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)',
      '  end tell',
      'end tell'
    ].join("\n"));
    const values = output.trim().split(",").map(Number);
    if (values.length !== 4 || values.some((value) => !Number.isFinite(value))) {
      throw new CommandProtocolError("DRIVER_ERROR", "Could not read the iPhone Mirroring window bounds");
    }
    const [left, top, width, height] = values as [number, number, number, number];
    return { left, top, width, height };
  }

  async clickElement(_elementIndex: number): Promise<void> {
    await this.appleScript([
      'tell application "System Events"',
      '  tell process "iPhone Mirroring"',
      '    if exists button "Resume" of front window then',
      '      click button "Resume" of front window',
      '    else',
      '      error "The Resume button is unavailable"',
      '    end if',
      '  end tell',
      'end tell'
    ].join("\n"));
  }

  async clickPoint(x: number, y: number): Promise<void> {
    await this.focus();
    const executable = await (this.clickExecutable ??= this.compileClickHelper());
    try {
      await executeFile(executable, [String(x), String(y)], { timeout: 5_000, killSignal: "SIGKILL" });
    } catch (error) {
      throw this.systemError("The launcher could not click the mirrored iPhone", error);
    }
  }

  async typeText(text: string): Promise<void> {
    await this.appleScript([
      'on run argv',
      '  tell application "System Events"',
      '    tell process "iPhone Mirroring" to set frontmost to true',
      '    keystroke (item 1 of argv)',
      '  end tell',
      'end run'
    ].join("\n"), [text]);
  }

  async pressKey(key: string): Promise<void> {
    const script = keyScript(key);
    if (!script) throw new CommandProtocolError("UNSUPPORTED_STEP", `The macOS launcher cannot press ${key}`);
    await this.appleScript([
      'tell application "System Events"',
      '  tell process "iPhone Mirroring" to set frontmost to true',
      `  ${script}`,
      'end tell'
    ].join("\n"));
  }

  async swipePoint(startX: number, startY: number, endX: number, endY: number): Promise<void> {
    await this.focus();
    const executable = await (this.swipeExecutable ??= this.compileSwipeHelper());
    try {
      await executeFile(executable, [String(startX), String(startY), String(endX), String(endY)], {
        timeout: 5_000,
        killSignal: "SIGKILL"
      });
      await wait(this.settleMs);
    } catch (error) {
      throw this.systemError("The launcher could not swipe the mirrored iPhone", error);
    }
  }

  async dispose(): Promise<void> {
    if (this.frameDirectory) await rm(this.frameDirectory, { recursive: true, force: true });
    this.frameDirectory = undefined;
    this.lastFrame = undefined;
  }

  private async accessibilitySnapshot(): Promise<string> {
    const output = await this.appleScript([
      'tell application "System Events"',
      '  tell process "iPhone Mirroring"',
      '    if not (exists front window) then error "No iPhone Mirroring window is open"',
      '    set snapshot to "Window: \\"iPhone Mirroring\\", App: iPhone Mirroring."',
      '    try',
      '      repeat with labelItem in (every static text of front window)',
      '        try',
      '          set snapshot to snapshot & linefeed & (value of labelItem as text)',
      '        end try',
      '      end repeat',
      '    end try',
      '    try',
      '      if exists button "Resume" of front window then set snapshot to snapshot & linefeed & "1 button Resume"',
      '    end try',
      '    return snapshot',
      '  end tell',
      'end tell'
    ].join("\n"));
    return output.trim();
  }

  private async capture(bounds: MirrorActionBounds): Promise<string> {
    const frameDirectory = await this.workingDirectory();
    if (this.lastFrame) await rm(this.lastFrame, { force: true });
    const framePath = join(frameDirectory, `frame-${Date.now()}.png`);
    const rectangle = `${Math.round(bounds.left)},${Math.round(bounds.top)},${Math.round(bounds.width)},${Math.round(bounds.height)}`;
    try {
      await executeFile("/usr/sbin/screencapture", ["-x", `-R${rectangle}`, framePath]);
    } catch (error) {
      throw this.systemError("Screen capture failed. Allow Screen Recording for the launcher, then try again", error);
    }
    this.lastFrame = framePath;
    return framePath;
  }

  private async compileClickHelper(): Promise<string> {
    const directory = await this.workingDirectory();
    const executable = join(directory, "mirror-click");
    const source = fileURLToPath(new URL("../native/mirror-click.swift", import.meta.url));
    try {
      await executeFile("/usr/bin/swiftc", [source, "-o", executable], { maxBuffer: 2 * 1024 * 1024 });
    } catch (error) {
      throw this.systemError("The launcher could not prepare mirrored iPhone tapping", error);
    }
    return executable;
  }

  private async compileSwipeHelper(): Promise<string> {
    const directory = await this.workingDirectory();
    const executable = join(directory, "mirror-swipe");
    const source = fileURLToPath(new URL("../native/mirror-swipe.swift", import.meta.url));
    try {
      await executeFile("/usr/bin/swiftc", [source, "-o", executable], { maxBuffer: 2 * 1024 * 1024 });
    } catch (error) {
      throw this.systemError("The launcher could not prepare mirrored iPhone swiping", error);
    }
    return executable;
  }

  private async workingDirectory(): Promise<string> {
    this.frameDirectory ??= await mkdtemp(join(tmpdir(), "iphone-command-launcher-"));
    return this.frameDirectory;
  }

  private async appleScript(source: string, args: string[] = []): Promise<string> {
    try {
      const result = await executeFile("/usr/bin/osascript", ["-e", source, ...args]);
      return result.stdout;
    } catch (error) {
      throw this.systemError(
        "iPhone Mirroring control failed. Allow Accessibility for the launcher and make sure iPhone Mirroring is available",
        error
      );
    }
  }

  private systemError(message: string, error: unknown): CommandProtocolError {
    const details = error instanceof Error ? error.message : String(error);
    return new CommandProtocolError("DRIVER_ERROR", message, {
      details: {
        setupAction: "Open System Settings → Privacy & Security, then allow iPhone Commands under Accessibility and Screen Recording",
        cause: details
      }
    });
  }

  private assertMacOs(): void {
    if (process.platform !== "darwin") {
      throw new CommandProtocolError("DRIVER_ERROR", "The iPhone Mirroring launcher requires macOS");
    }
  }
}

/**
 * `screencapture` is asked for a rectangle in points and writes a file in pixels. The ratio is
 * how much detail the capture actually carries, and a Retina Mac gives 2.
 *
 * It silently drops to 1 whenever the display holding the mirror window is not backed at 2x —
 * an AirPlay TV, Sidecar, a plugged-in 1080p monitor. None of those announce themselves, none of
 * them are facts about this package, and any of them can start in the middle of a session
 * because of where someone decided to sit. Measuring the artifact is the only check that
 * survives that, which is why this reads the file rather than inspecting the display list.
 */
export function captureScale(bytes: Uint8Array, bounds: MirrorActionBounds): number | undefined {
  const pixelWidth = pngPixelWidth(bytes);
  if (pixelWidth === undefined || !(bounds.width > 0)) return undefined;
  return Number((pixelWidth / bounds.width).toFixed(3));
}

/** A PNG opens with an 8-byte signature, a 4-byte chunk length, `IHDR`, then width as big-endian. */
function pngPixelWidth(bytes: Uint8Array): number | undefined {
  if (bytes.length < 24) return undefined;
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (signature.some((value, index) => bytes[index] !== value)) return undefined;
  if (String.fromCharCode(bytes[12]!, bytes[13]!, bytes[14]!, bytes[15]!) !== "IHDR") return undefined;
  return (((bytes[16]! << 24) | (bytes[17]! << 16) | (bytes[18]! << 8) | bytes[19]!) >>> 0) || undefined;
}

function keyScript(key: string): string | undefined {
  const scripts: Record<string, string> = {
    "super+1": 'keystroke "1" using command down',
    "super+2": 'keystroke "2" using command down',
    "super+3": 'keystroke "3" using command down',
    Return: "key code 36",
    Escape: "key code 53"
  };
  return scripts[key];
}

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
