import assert from "node:assert/strict";
import test from "node:test";

import { encode } from "jpeg-js";

import { TemplateScreenResolver, type MirrorFrame } from "../src/index.js";

const solidFrame = (level: number): MirrorFrame => {
  const width = 32;
  const height = 48;
  const data = Buffer.alloc(width * height * 4);
  for (let offset = 0; offset < data.length; offset += 4) {
    data[offset] = level;
    data[offset + 1] = level;
    data[offset + 2] = level;
    data[offset + 3] = 255;
  }
  return {
    bytes: encode({ data, width, height }, 90).data,
    mediaType: "image/jpeg",
    reference: `memory://solid-${level}`
  };
};

test("recognizes a matching screen template and rejects a different screen", async () => {
  const resolver = new TemplateScreenResolver(
    [{ label: "Settings", frame: solidFrame(230) }],
    { threshold: 0.9 }
  );

  const match = await resolver.observe({ accessibilityText: "window", frame: solidFrame(225) });
  const miss = await resolver.observe({ accessibilityText: "window", frame: solidFrame(20) });

  assert.deepEqual(match.screenText, ["Settings"]);
  assert.deepEqual(miss.screenText, []);
});
