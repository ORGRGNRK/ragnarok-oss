import { CommandProtocolError } from "./errors.js";
import { assertMirrorReady, classifyMirrorState } from "./mirror-state.js";
import type {
  DriverActionResult,
  DriverObservation,
  DriverSession,
  DriverStep,
  MirrorActionBounds,
  MirrorControlPort,
  MirrorHostState,
  MirrorObservationResolver,
  ResolvedTarget
} from "./runtime-types.js";
import type { PortableTarget } from "./types.js";
import type { NormalizedPoint, SwipeStep } from "./types.js";
import type { DriverAction } from "./types.js";

export interface IPhoneMirroringDriverOptions {
  port: MirrorControlPort;
  resolver: MirrorObservationResolver;
  actionBounds: MirrorActionBounds;
  appName?: string;
  actions?: DriverAction[];
  clock?: () => Date;
}

export class IPhoneMirroringDriver {
  private readonly port: MirrorControlPort;
  private readonly resolver: MirrorObservationResolver;
  private readonly actionBounds: MirrorActionBounds;
  private readonly appName: string;
  private readonly clock: () => Date;
  private readonly actions: DriverAction[];
  private active = false;

  constructor(options: IPhoneMirroringDriverOptions) {
    this.port = options.port;
    this.resolver = options.resolver;
    this.actionBounds = options.actionBounds;
    this.appName = options.appName ?? "iPhone Mirroring";
    this.clock = options.clock ?? (() => new Date());
    this.actions = options.actions ?? ["openApp", "tap", "typeText", "swipe", "press"];
  }

  async startSession(): Promise<DriverSession> {
    await this.port.focus();
    let state = await this.port.getState();

    const resumeIndex = resumeElementIndex(state.accessibilityText);
    if (classifyMirrorState(state.accessibilityText, this.appName).kind === "paused" && resumeIndex !== undefined) {
      await this.port.clickElement(resumeIndex);
      state = await this.port.getState();
    }
    assertMirrorReady(state.accessibilityText, this.appName);

    this.active = true;
    return {
      id: "iphone-mirroring",
      version: "0.1",
      capabilities: {
        actions: [...this.actions],
        observations: [...this.resolver.capabilities]
      }
    };
  }

  async stopSession(): Promise<void> {
    this.active = false;
  }

  async observe(): Promise<DriverObservation> {
    this.ensureActive();
    const state = await this.checkedState();
    const resolved = await this.resolver.observe(state);
    return { capturedAt: this.clock().toISOString(), ...resolved };
  }

  async execute(step: DriverStep): Promise<DriverActionResult> {
    this.ensureActive();
    await this.checkedState();
    switch (step.action) {
      case "openApp":
        return this.openApp(step.app.name ?? step.app.bundleId ?? "");
      case "tap":
        return this.tap(step.target);
      case "typeText":
        if (step.target) {
          const result = await this.tap(step.target);
          await this.port.typeText(step.text);
          return result;
        }
        await this.port.typeText(step.text);
        return {};
      case "swipe":
        return this.swipe(step);
      case "press":
        await this.port.pressKey(keyForButton(step.button));
        return {};
    }
  }

  private async swipe(step: SwipeStep): Promise<DriverActionResult> {
    const path = toSwipePath(step.direction, step.from, step.distance);
    const start = toActionPoint(path.from, this.actionBounds);
    const end = toActionPoint(path.to, this.actionBounds);
    await this.port.swipePoint(start.x, start.y, end.x, end.y);
    return {
      metadata: {
        direction: step.direction,
        distance: path.distance,
        from: path.from,
        to: path.to
      }
    };
  }

  private async openApp(query: string): Promise<DriverActionResult> {
    if (!query) throw new CommandProtocolError("DRIVER_ERROR", "openApp requires an app name or bundle id");
    await this.port.pressKey("super+1");
    await this.checkedState();
    await this.port.pressKey("super+3");
    await this.checkedState();
    await this.port.typeText(query);
    // iOS 27 can accept the query before its Settings result is ready. A second observed
    // settle cycle keeps target resolution from racing the result list.
    await this.checkedState();
    const searchState = await this.checkedState();
    const resolved = await this.resolver.resolveTarget?.(searchState, { text: query, minimumConfidence: 0.8 });
    if (resolved && resolved.confidence >= 0.8) {
      const point = toActionPoint(resolved.point, this.actionBounds);
      await this.port.clickPoint(point.x, point.y);
      await this.checkedState();
      return { resolvedTarget: resolved, metadata: { strategy: "spotlightText", query } };
    }
    await this.port.pressKey("Return");
    await this.checkedState();
    return { metadata: { strategy: "spotlight", query } };
  }

  private async tap(target: PortableTarget): Promise<DriverActionResult> {
    const state = await this.checkedState();
    const resolved = await this.resolveTarget(state, target);
    const requiredConfidence = target.minimumConfidence ?? 0;
    if (resolved.confidence < requiredConfidence) {
      throw new CommandProtocolError(
        "TARGET_CONFIDENCE",
        `Resolved target confidence ${resolved.confidence.toFixed(3)} is below ${requiredConfidence.toFixed(3)}`,
        { details: resolved }
      );
    }

    const point = toActionPoint(resolved.point, this.actionBounds);
    await this.port.clickPoint(point.x, point.y);
    return { resolvedTarget: resolved };
  }

  private async resolveTarget(state: MirrorHostState, target: PortableTarget): Promise<ResolvedTarget> {
    const semantic = await this.resolver.resolveTarget?.(state, target);
    if (semantic) return semantic;
    if (target.fallbackPoint) {
      return {
        strategy: "fallbackPoint",
        confidence: 0.5,
        point: target.fallbackPoint,
        clue: "portable normalized fallback"
      };
    }
    throw new CommandProtocolError("TARGET_NOT_FOUND", "The mirror resolver could not locate the requested target", {
      details: target
    });
  }

  private ensureActive(): void {
    if (!this.active) throw new CommandProtocolError("DRIVER_ERROR", "Mirror driver session is not active");
  }

  private async checkedState(): Promise<MirrorHostState> {
    const state = await this.port.getState();
    assertMirrorReady(state.accessibilityText, this.appName);
    return state;
  }
}

export interface NormalizedSwipePath {
  from: NormalizedPoint;
  to: NormalizedPoint;
  distance: number;
}

const SWIPE_INSET = 0.08;
const DEFAULT_SWIPE_DISTANCE = 0.45;

/** Converts a portable swipe into a safe, bounded path inside the mirrored phone window. */
export function toSwipePath(
  direction: SwipeStep["direction"],
  from?: NormalizedPoint,
  distance = DEFAULT_SWIPE_DISTANCE
): NormalizedSwipePath {
  const defaultFrom: Record<SwipeStep["direction"], NormalizedPoint> = {
    up: { x: 0.5, y: 0.72 },
    down: { x: 0.5, y: 0.28 },
    left: { x: 0.72, y: 0.5 },
    right: { x: 0.28, y: 0.5 }
  };
  const start = {
    x: roundNormalized(clamp(from?.x ?? defaultFrom[direction].x, SWIPE_INSET, 1 - SWIPE_INSET)),
    y: roundNormalized(clamp(from?.y ?? defaultFrom[direction].y, SWIPE_INSET, 1 - SWIPE_INSET))
  };
  const delta = {
    up: { x: 0, y: -distance },
    down: { x: 0, y: distance },
    left: { x: -distance, y: 0 },
    right: { x: distance, y: 0 }
  }[direction];
  const end = {
    x: roundNormalized(clamp(start.x + delta.x, SWIPE_INSET, 1 - SWIPE_INSET)),
    y: roundNormalized(clamp(start.y + delta.y, SWIPE_INSET, 1 - SWIPE_INSET))
  };
  const actualDistance = Math.hypot(end.x - start.x, end.y - start.y);
  if (actualDistance < 0.05) {
    throw new CommandProtocolError(
      "DRIVER_ERROR",
      `Swipe ${direction} cannot move far enough from the requested starting point`,
      { details: { direction, from: start, distance } }
    );
  }
  return { from: start, to: end, distance: Number(actualDistance.toFixed(3)) };
}

function resumeElementIndex(accessibilityText: string): number | undefined {
  const match = accessibilityText.match(/(?:^|\n)\s*(\d+)\s+button Resume\b/m);
  return match ? Number(match[1]) : undefined;
}

function keyForButton(button: "home" | "appSwitcher" | "back"): string {
  switch (button) {
    case "home":
      return "super+1";
    case "appSwitcher":
      return "super+2";
    case "back":
      return "Escape";
  }
}

function toActionPoint(
  point: { x: number; y: number },
  bounds: MirrorActionBounds
): { x: number; y: number } {
  return {
    x: bounds.left + point.x * bounds.width,
    y: bounds.top + point.y * bounds.height
  };
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

function roundNormalized(value: number): number {
  return Number(value.toFixed(6));
}
