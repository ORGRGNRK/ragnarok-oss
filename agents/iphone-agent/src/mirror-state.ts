import { CommandProtocolError } from "./errors.js";

export type MirrorStateKind =
  | "ready"
  | "paused"
  | "disconnected"
  | "locked"
  | "permission"
  | "obscured"
  | "unexpectedDialog";

export interface ClassifiedMirrorState {
  kind: MirrorStateKind;
  message: string;
}

export function classifyMirrorState(accessibilityText: string, appName = "iPhone Mirroring"): ClassifiedMirrorState {
  const text = accessibilityText.toLocaleLowerCase();
  if (/permission|privacy\s*&\s*security|access (?:is )?required|allow .*iphone mirroring/.test(text)) {
    return { kind: "permission", message: "iPhone Mirroring needs a macOS permission" };
  }
  if (/unable to connect|not connected|connection (?:lost|failed)|iphone (?:is )?unavailable|disconnected/.test(text)) {
    return { kind: "disconnected", message: "The mirrored iPhone is disconnected" };
  }
  if (/unlock (?:your )?iphone|iphone (?:is )?locked|locked iphone/.test(text)) {
    return { kind: "locked", message: "The mirrored iPhone is locked" };
  }
  if (/iphone in use|airplay|screen (?:is being )?(?:shared|recorded)|mirroring (?:is )?unavailable while/.test(text)) {
    return { kind: "obscured", message: "The mirrored iPhone screen is obscured or in use elsewhere" };
  }
  if (/connection paused/.test(text)) {
    return { kind: "paused", message: "The iPhone Mirroring connection is paused" };
  }
  if (/\b(?:dialog|alert|sheet)\b/.test(text)) {
    return { kind: "unexpectedDialog", message: "An unexpected iPhone Mirroring dialog is open" };
  }
  if (!text.includes(appName.toLocaleLowerCase())) {
    return { kind: "disconnected", message: `Could not verify the ${appName} window` };
  }
  return { kind: "ready", message: "iPhone Mirroring is ready" };
}

export function assertMirrorReady(accessibilityText: string, appName = "iPhone Mirroring"): void {
  const state = classifyMirrorState(accessibilityText, appName);
  if (state.kind !== "ready") {
    throw new CommandProtocolError("DRIVER_ERROR", state.message, { details: { mirrorState: state.kind } });
  }
}
