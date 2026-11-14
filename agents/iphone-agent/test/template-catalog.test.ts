import assert from "node:assert/strict";
import { mkdtemp, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { encode } from "jpeg-js";

import { CommandProtocolError, FileTemplateCatalog } from "../src/index.js";

function jpeg(level: number): Buffer {
  const width = 16;
  const height = 24;
  const data = Buffer.alloc(width * height * 4);
  for (let offset = 0; offset < data.length; offset += 4) {
    data[offset] = level;
    data[offset + 1] = level;
    data[offset + 2] = level;
    data[offset + 3] = 255;
  }
  return encode({ data, width, height }, 90).data;
}

test("file template catalog loads compatible JPEG templates from a durable manifest", async () => {
  const directory = await mkdtemp(join(tmpdir(), "iphone-template-catalog-"));
  await writeFile(join(directory, "settings.jpg"), jpeg(220));
  await writeFile(join(directory, "old.jpg"), jpeg(30));
  const manifestPath = join(directory, "manifest.json");
  await writeFile(manifestPath, JSON.stringify({
    schemaVersion: "0.1",
    threshold: 0.9,
    templates: [
      { label: "Settings", file: "settings.jpg", mediaType: "image/jpeg", compatibility: { osVersion: "27" } },
      { label: "Old", file: "old.jpg", mediaType: "image/jpeg", compatibility: { osVersion: "26" } }
    ]
  }));

  const catalog = await FileTemplateCatalog.load(manifestPath, { compatibility: { osVersion: "27" } });
  const observation = await catalog.resolver.observe({
    accessibilityText: "iPhone Mirroring",
    frame: { bytes: jpeg(218), mediaType: "image/jpeg", reference: "memory://current" }
  });

  assert.equal(catalog.templates.length, 1);
  assert.deepEqual(observation.screenText, ["Settings"]);
  assert.equal(catalog.templates[0]?.frame.reference, await realpath(join(directory, "settings.jpg")));
});

test("file template catalog rejects paths outside the manifest directory", async () => {
  const directory = await mkdtemp(join(tmpdir(), "iphone-template-escape-"));
  const manifestPath = join(directory, "manifest.json");
  await writeFile(manifestPath, JSON.stringify({
    schemaVersion: "0.1",
    templates: [{ label: "Escape", file: "../outside.jpg", mediaType: "image/jpeg" }]
  }));

  await assert.rejects(
    FileTemplateCatalog.load(manifestPath),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );
});
