import assert from "node:assert/strict";
import test from "node:test";

import {
  DeterministicRunner,
  captureScale,
  degradedCaptureNote,
  parseCommand,
  type DriverActionResult,
  type DriverObservation,
  type DriverSession,
  type DriverStep,
  type PortableDriver
} from "../src/index.js";

/** The first 24 bytes are all the scale check reads: signature, chunk length, IHDR, width. */
function pngHeader(pixelWidth: number, pixelHeight = 100): Uint8Array {
  const bytes = new Uint8Array(24);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  bytes.set([0, 0, 0, 13], 8);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  new DataView(bytes.buffer).setUint32(16, pixelWidth);
  new DataView(bytes.buffer).setUint32(20, pixelHeight);
  return bytes;
}

const window381 = { left: 175, top: 33, width: 381, height: 824 };

test("a Retina capture measures 2x and a mirrored one measures 1x", () => {
  assert.equal(captureScale(pngHeader(762), window381), 2);
  // The real reading from 2026-08-20, with the Mac mirrored to an AirPlay TV.
  assert.equal(captureScale(pngHeader(449), { ...window381, width: 449 }), 1);
});

test("the scale check refuses to guess", () => {
  assert.equal(captureScale(pngHeader(762), { ...window381, width: 0 }), undefined);
  assert.equal(captureScale(new Uint8Array([1, 2, 3]), window381), undefined, "too short to be a PNG");
  assert.equal(captureScale(new Uint8Array(24), window381), undefined, "not a PNG signature");
});

test("only a degraded capture gets an explanation", () => {
  assert.equal(degradedCaptureNote({ capturedAt: "2026-08-20T12:00:00.000Z", captureScale: 2 }), undefined);
  assert.equal(degradedCaptureNote({ capturedAt: "2026-08-20T12:00:00.000Z" }), undefined, "unmeasured is not degraded");

  const note = degradedCaptureNote({ capturedAt: "2026-08-20T12:00:00.000Z", captureScale: 1 });
  assert.match(note ?? "", /captured at 1x instead of 2x/);
  assert.match(note ?? "", /mirrored or extended to another screen/);
});

class ScaledDriver implements PortableDriver {
  constructor(private readonly scale?: number) {}

  async startSession(): Promise<DriverSession> {
    return {
      id: "scaled-fake",
      version: "test",
      capabilities: { actions: ["openApp"], observations: ["screenshot", "screenText"] }
    };
  }

  async observe(): Promise<DriverObservation> {
    return {
      capturedAt: "2026-08-20T12:00:00.000Z",
      // What OCR returns off a 1x capture: the row is there, but misread.
      screenText: ["General", "AbLKrt"],
      ...(this.scale === undefined ? {} : { captureScale: this.scale })
    };
  }

  async execute(_step: DriverStep): Promise<DriverActionResult> {
    return {};
  }
}

const command = parseCommand(JSON.stringify({
  schemaVersion: "0.1",
  version: "1.0.0",
  id: "com.yggdrasil.iphone.scale-probe",
  name: "Scale probe",
  safety: { risk: "reversible" },
  steps: [{
    id: "open-general",
    action: "openApp",
    app: { name: "General" },
    expect: { screenText: "About" }
  }]
}), "json");

test("a text check that fails on a degraded capture says why", async () => {
  const receipt = await new DeterministicRunner(new ScaledDriver(1), { idFactory: () => "run-scale-low" })
    .run({ command });

  assert.equal(receipt.status, "failed");
  const message = receipt.steps.at(-1)?.verification?.message ?? "";
  assert.match(message, /screen text does not contain/, "keeps the original reason");
  assert.match(message, /captured at 1x instead of 2x/, "and adds the likely cause");
});

test("the same failure at full scale is not blamed on the display", async () => {
  const receipt = await new DeterministicRunner(new ScaledDriver(2), { idFactory: () => "run-scale-ok" })
    .run({ command });

  assert.equal(receipt.status, "failed");
  const message = receipt.steps.at(-1)?.verification?.message ?? "";
  assert.match(message, /screen text does not contain/);
  assert.doesNotMatch(message, /captured at/);
});
