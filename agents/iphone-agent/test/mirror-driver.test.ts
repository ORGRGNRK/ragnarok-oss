import assert from "node:assert/strict";
import test from "node:test";

import {
  CommandProtocolError,
  IPhoneMirroringDriver,
  classifyMirrorState,
  type MirrorControlPort,
  type MirrorHostState,
  type MirrorObservationResolver
} from "../src/index.js";

class FakeMirrorPort implements MirrorControlPort {
  readonly events: Array<{ name: string; value?: unknown }> = [];
  state: MirrorHostState = {
    accessibilityText: 'Window: "iPhone Mirroring", App: iPhone Mirroring.'
  };

  async focus(): Promise<void> {
    this.events.push({ name: "focus" });
  }

  async getState(): Promise<MirrorHostState> {
    this.events.push({ name: "getState" });
    return structuredClone(this.state);
  }

  async clickElement(elementIndex: number): Promise<void> {
    this.events.push({ name: "clickElement", value: elementIndex });
    this.state.accessibilityText = 'Window: "iPhone Mirroring", App: iPhone Mirroring.';
  }

  async clickPoint(x: number, y: number): Promise<void> {
    this.events.push({ name: "clickPoint", value: { x, y } });
  }

  async typeText(text: string): Promise<void> {
    this.events.push({ name: "typeText", value: text });
  }

  async pressKey(key: string): Promise<void> {
    this.events.push({ name: "pressKey", value: key });
  }

  async swipePoint(startX: number, startY: number, endX: number, endY: number): Promise<void> {
    this.events.push({ name: "swipePoint", value: { startX, startY, endX, endY } });
  }
}

const resolver: MirrorObservationResolver = {
  capabilities: ["screenshot", "screenText"],
  async observe() {
    return { screenText: ["Settings"], screenshotRef: "memory://frame" };
  }
};

const makeDriver = (port: FakeMirrorPort): IPhoneMirroringDriver =>
  new IPhoneMirroringDriver({
    port,
    resolver,
    actionBounds: { left: 10, top: 20, width: 400, height: 800 }
  });

test("resumes a paused mirror session and exposes verified capabilities", async () => {
  const port = new FakeMirrorPort();
  port.state.accessibilityText = [
    'Window: "iPhone Mirroring", App: iPhone Mirroring.',
    "  3 text Connection Paused",
    "  4 button Resume"
  ].join("\n");
  const driver = makeDriver(port);

  const session = await driver.startSession();

  assert.equal(session.id, "iphone-mirroring");
  assert.ok(session.capabilities.actions.includes("openApp"));
  assert.deepEqual(port.events.find((event) => event.name === "clickElement")?.value, 4);
});

test("advertises only actions enabled by a concrete mirror port", async () => {
  const port = new FakeMirrorPort();
  const driver = new IPhoneMirroringDriver({
    port,
    resolver,
    actionBounds: { left: 10, top: 20, width: 400, height: 800 },
    actions: ["openApp", "tap", "typeText", "press"]
  });

  const session = await driver.startSession();

  assert.equal(session.capabilities.actions.includes("swipe"), false);
});

test("translates openApp into deterministic Home and Spotlight controls", async () => {
  const port = new FakeMirrorPort();
  const driver = makeDriver(port);
  await driver.startSession();

  await driver.execute({
    id: "open",
    action: "openApp",
    app: { name: "Settings", bundleId: "com.apple.Preferences" }
  });

  assert.deepEqual(
    port.events.filter((event) => event.name === "pressKey" || event.name === "typeText"),
    [
      { name: "pressKey", value: "super+1" },
      { name: "pressKey", value: "super+3" },
      { name: "typeText", value: "Settings" },
      { name: "pressKey", value: "Return" }
    ]
  );
});

test("taps an exact Spotlight result when the resolver can see it", async () => {
  const port = new FakeMirrorPort();
  const driver = new IPhoneMirroringDriver({
    port,
    resolver: {
      capabilities: ["screenshot", "screenText", "target"],
      async observe() {
        return { screenText: ["General"] };
      },
      async resolveTarget() {
        return {
          strategy: "macOS Vision text",
          confidence: 0.95,
          point: { x: 0.25, y: 0.4 },
          clue: "General"
        };
      }
    },
    actionBounds: { left: 10, top: 20, width: 400, height: 800 }
  });
  await driver.startSession();

  const result = await driver.execute({ id: "open", action: "openApp", app: { name: "General" } });

  assert.deepEqual(port.events.at(-2), { name: "clickPoint", value: { x: 110, y: 340 } });
  assert.equal(result.metadata?.strategy, "spotlightText");
  assert.equal(port.events.some((event) => event.name === "pressKey" && event.value === "Return"), false);
});

test("maps a normalized fallback point into bounded mirror coordinates", async () => {
  const port = new FakeMirrorPort();
  const driver = makeDriver(port);
  await driver.startSession();

  const result = await driver.execute({
    id: "tap",
    action: "tap",
    target: { fallbackPoint: { x: 0.25, y: 0.5 }, minimumConfidence: 0.5 }
  });

  assert.deepEqual(port.events.at(-1), { name: "clickPoint", value: { x: 110, y: 420 } });
  assert.equal(result.resolvedTarget?.strategy, "fallbackPoint");
});

test("maps a portable swipe into bounded mirror coordinates", async () => {
  const port = new FakeMirrorPort();
  const driver = makeDriver(port);
  await driver.startSession();

  const result = await driver.execute({
    id: "swipe",
    action: "swipe",
    direction: "up",
    from: { x: 0.4, y: 0.8 },
    distance: 0.5
  });

  assert.deepEqual(port.events.at(-1), {
    name: "swipePoint",
    value: { startX: 170, startY: 660, endX: 170, endY: 260 }
  });
  assert.deepEqual(result.metadata, {
    direction: "up",
    distance: 0.5,
    from: { x: 0.4, y: 0.8 },
    to: { x: 0.4, y: 0.3 }
  });
});

test("refuses a swipe that starts against its destination edge", async () => {
  const port = new FakeMirrorPort();
  const driver = makeDriver(port);
  await driver.startSession();

  await assert.rejects(
    driver.execute({ id: "swipe", action: "swipe", direction: "up", from: { x: 0.5, y: 0 } }),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "DRIVER_ERROR"
  );
  assert.equal(port.events.some((event) => event.name === "swipePoint"), false);
});

test("refuses a fallback point below the command confidence threshold", async () => {
  const port = new FakeMirrorPort();
  const driver = makeDriver(port);
  await driver.startSession();

  await assert.rejects(
    driver.execute({
      id: "tap",
      action: "tap",
      target: { fallbackPoint: { x: 0.5, y: 0.5 }, minimumConfidence: 0.9 }
    }),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "TARGET_CONFIDENCE"
  );
  assert.equal(port.events.some((event) => event.name === "clickPoint"), false);
});

test("classifies blocked mirror states with machine-readable reasons", () => {
  assert.equal(classifyMirrorState("iPhone Mirroring\nConnection Paused").kind, "paused");
  assert.equal(classifyMirrorState("iPhone Mirroring\nUnlock your iPhone").kind, "locked");
  assert.equal(classifyMirrorState("iPhone Mirroring\nUnable to Connect").kind, "disconnected");
  assert.equal(classifyMirrorState("iPhone Mirroring\nScreen Recording permission required").kind, "permission");
  assert.equal(classifyMirrorState("iPhone Mirroring\niPhone in Use").kind, "obscured");
  assert.equal(classifyMirrorState("iPhone Mirroring\n1 alert Unexpected Error").kind, "unexpectedDialog");
});

test("stops before phone input when the mirror has an unexpected dialog", async () => {
  const port = new FakeMirrorPort();
  port.state.accessibilityText = 'Window: "iPhone Mirroring"\n1 alert Unexpected Error';
  const driver = makeDriver(port);

  await assert.rejects(
    driver.startSession(),
    (error: unknown) => error instanceof CommandProtocolError &&
      error.code === "DRIVER_ERROR" &&
      (error.details as { mirrorState?: string }).mirrorState === "unexpectedDialog"
  );
  assert.equal(port.events.some((event) => event.name === "clickPoint"), false);
});
