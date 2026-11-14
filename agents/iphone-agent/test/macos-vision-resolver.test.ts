import assert from "node:assert/strict";
import test from "node:test";

import { inferVisibleApp, parseRecognizedText, resolveRecognizedTarget } from "../src/macos-vision-resolver.js";

test("Vision OCR output resolves a text row to portable screen coordinates", () => {
  const recognized = parseRecognizedText(JSON.stringify([
    { text: "General", confidence: 0.98, x: 0.08, y: 0.61, width: 0.24, height: 0.04 },
    { text: "About", confidence: 0.96, x: 0.08, y: 0.79, width: 0.18, height: 0.04 }
  ]));

  const resolved = resolveRecognizedTarget(recognized, { text: "About", minimumConfidence: 0.8 });
  assert.equal(resolved?.strategy, "macOS Vision text");
  assert.equal(resolved?.clue, "About");
  assert.ok((resolved?.confidence ?? 0) >= 0.9);
  assert.ok(Math.abs((resolved?.point.x ?? 0) - 0.17) < 0.001);
  assert.ok(Math.abs((resolved?.point.y ?? 0) - 0.19) < 0.001);
});

test("recognizes Settings from the iOS 27 Battery Health screen", () => {
  assert.deepEqual(
    inferVisibleApp([
      "Battery Health",
      "Maximum Capacity 93%",
      "Cycle Count 343",
      "Manufacture Date September 2024",
      "First Use November 2024"
    ]),
    { name: "Settings", bundleId: "com.apple.Preferences" }
  );
});

test("does not infer Settings from one generic clue", () => {
  assert.equal(inferVisibleApp(["Battery", "Maximum Capacity"]), undefined);
});
