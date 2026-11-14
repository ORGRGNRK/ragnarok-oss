import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { ConfirmationDecision, ConfirmationProvider, ConfirmationRequest } from "./runtime-types.js";

const executeFile = promisify(execFile);

/**
 * The shortest path between "the runner is about to commit" and "a person looked at the real
 * screen and said yes". The dialog is drawn by macOS itself, so nothing in the launcher page can
 * forge it, pre-answer it, or replay it, and the runner blocks naturally while it is open.
 *
 * Every outcome other than pressing Approve is a denial: the cancel button, the Escape key, the
 * timeout, and any failure to show the dialog at all. Silence never means yes.
 */
export interface MacOsDialogConfirmationOptions {
  /** How long the dialog waits before denying on its own. */
  timeoutMs?: number;
  actor?: string;
}

export class MacOsDialogConfirmationProvider implements ConfirmationProvider {
  private readonly timeoutMs: number;
  private readonly actor: string;

  constructor(options: MacOsDialogConfirmationOptions = {}) {
    this.timeoutMs = options.timeoutMs ?? 120_000;
    this.actor = options.actor ?? "macOS dialog";
  }

  async confirm(request: ConfirmationRequest): Promise<ConfirmationDecision> {
    if (process.platform !== "darwin") return { approved: false, actor: this.actor };

    const seconds = Math.max(5, Math.round(this.timeoutMs / 1000));
    try {
      const result = await executeFile(
        "/usr/bin/osascript",
        ["-e", dialogScript, dialogText(request), "iPhone Commands", String(seconds)],
        { timeout: this.timeoutMs + 5_000, killSignal: "SIGKILL" }
      );
      return { approved: result.stdout.trim() === "approved", actor: this.actor };
    } catch {
      // Cancel, Escape, a killed dialog, and a missing WindowServer session all land here.
      return { approved: false, actor: this.actor };
    }
  }
}

/**
 * The text is passed as an argument rather than interpolated into the script, so a command name
 * or a recognized screen label can never close a quote and become AppleScript.
 */
const dialogScript = [
  'on run argv',
  '  set dialogText to item 1 of argv',
  '  set dialogTitle to item 2 of argv',
  '  set timeoutSeconds to (item 3 of argv) as integer',
  '  tell application "System Events"',
  '    activate',
  '    set answer to display dialog dialogText with title dialogTitle buttons {"Deny", "Approve"} default button "Deny" cancel button "Deny" with icon caution giving up after timeoutSeconds',
  '  end tell',
  '  if gave up of answer then return "denied"',
  '  if button returned of answer is "Approve" then return "approved"',
  '  return "denied"',
  'end run'
].join("\n");

function dialogText(request: ConfirmationRequest): string {
  const lines = [
    `${request.command.name} wants to do something that cannot be undone from here.`,
    "",
    request.message,
    "",
    `Risk: ${request.risk}`
  ];

  const app = request.observed?.app?.name ?? request.observed?.app?.bundleId;
  if (app) lines.push(`On screen now: ${app}`);
  lines.push("", "Look at the mirrored iPhone before you answer. Approve only if the screen shows what you expect.");
  return lines.join("\n");
}
