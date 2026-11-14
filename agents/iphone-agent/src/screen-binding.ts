import type { DriverObservation } from "./runtime-types.js";

/**
 * A mirrored iPhone screen is never perfectly still. The status bar carries a clock that
 * changes every minute and a battery reading that changes on its own schedule, so comparing
 * whole frames — or even the raw recognized text — would void a person's approval for reasons
 * that have nothing to do with what they approved. Binding therefore drops the content that is
 * known to move on its own and compares what is left, including where it sits.
 *
 * The filter is deliberately narrow. Anything it does not recognize as volatile is kept, so an
 * unexpected change voids the approval rather than slipping past it.
 */

/**
 * Recognized text whose vertical centre sits within this fraction of the top of the mirrored
 * window is treated as status bar.
 *
 * Measured, not assumed. On a live 381x824 mirror window the status bar clock sits at 0.0710 and
 * the first real content — the navigation title — at 0.1165, because the captured window
 * includes bezel chrome above the phone screen itself. A band sized from the phone's own 2%
 * status bar would sit above the clock and miss it, leaving carrier and battery text to void
 * approvals for no reason. This band clears the clock with margin and stays well clear of the
 * navigation title.
 */
export const STATUS_BAR_BAND = 0.09;

/**
 * Positions are compared on a grid rather than exactly, so that sub-pixel differences between
 * two captures of the same screen do not read as movement. One cell is about 1.6% of the
 * window, well below the size of anything tappable.
 */
export const POSITION_GRID = 64;

/** Clock readings and battery percentages change without anyone touching the phone. */
const volatilePatterns = [
  /^\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?$/i,
  /^\d{1,3}\s*%$/
];

interface PositionedText {
  text: string;
  /** Normalized centre with a top-left origin, matching how the driver taps. */
  x: number;
  y: number;
}

export interface ScreenBinding {
  /** Sorted `text@x,y` entries for every non-volatile line, or bare text when the driver reports no positions. */
  entries: string[];
  /** True when the source observation carried bounding boxes, so positions were compared. */
  positioned: boolean;
  app?: string;
}

export interface BindingComparison {
  stable: boolean;
  reason?: string;
}

/** Reduce an observation to the facts an approval is bound to. */
export function bindScreen(observation: DriverObservation): ScreenBinding {
  const positioned = readPositionedText(observation);
  const app = observation.app?.bundleId ?? observation.app?.name;

  if (positioned) {
    const entries = positioned
      .filter((item) => item.y >= STATUS_BAR_BAND)
      .map((item) => ({ ...item, text: normalizeText(item.text) }))
      .filter((item) => item.text.length > 0 && !isVolatile(item.text))
      .map((item) => `${item.text}@${quantize(item.x)},${quantize(item.y)}`)
      .sort();
    return { entries, positioned: true, ...(app ? { app } : {}) };
  }

  const entries = (observation.screenText ?? [])
    .map(normalizeText)
    .filter((text) => text.length > 0 && !isVolatile(text))
    .sort();
  return { entries, positioned: false, ...(app ? { app } : {}) };
}

/**
 * Compare an approved binding with one taken immediately before the action runs. Reasons carry
 * counts rather than recognized text, so a denied approval never writes screen content to a log.
 */
export function compareBinding(approved: ScreenBinding, current: ScreenBinding): BindingComparison {
  if (approved.app !== current.app) {
    return { stable: false, reason: "a different app is in the foreground" };
  }
  if (approved.positioned !== current.positioned) {
    return { stable: false, reason: "the screen is no longer being observed the same way" };
  }

  const approvedEntries = new Set(approved.entries);
  const currentEntries = new Set(current.entries);
  const removed = [...approvedEntries].filter((entry) => !currentEntries.has(entry)).length;
  const added = [...currentEntries].filter((entry) => !approvedEntries.has(entry)).length;
  if (removed === 0 && added === 0) return { stable: true };

  const moved = approved.positioned ? " or moved" : "";
  return {
    stable: false,
    reason: `${removed} item${removed === 1 ? "" : "s"} left${moved} and ${added} appeared since you were asked`
  };
}

function isVolatile(normalized: string): boolean {
  return volatilePatterns.some((pattern) => pattern.test(normalized));
}

function quantize(value: number): number {
  return Math.round(value * POSITION_GRID);
}

/**
 * The macOS resolver reports every recognized line with a normalized bounding box in
 * `metadata.recognizedText`. Vision uses a bottom-left origin, so the centre is flipped here to
 * match the top-left origin the mirror driver taps in.
 */
function readPositionedText(observation: DriverObservation): PositionedText[] | undefined {
  const raw = observation.metadata?.recognizedText;
  if (!Array.isArray(raw)) return undefined;

  const items: PositionedText[] = [];
  for (const value of raw) {
    if (!value || typeof value !== "object") return undefined;
    const item = value as Record<string, unknown>;
    if (typeof item.text !== "string") return undefined;
    const numbers = ["x", "y", "height"].map((key) => item[key]);
    if (!numbers.every((entry) => typeof entry === "number" && Number.isFinite(entry))) return undefined;
    const [x, y, height] = numbers as [number, number, number];
    const width = typeof item.width === "number" && Number.isFinite(item.width) ? item.width : 0;
    items.push({ text: item.text, x: x + width / 2, y: 1 - (y + height / 2) });
  }
  return items;
}

function normalizeText(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase().replace(/[^\p{L}\p{N}%:.]+/gu, " ").trim();
}
