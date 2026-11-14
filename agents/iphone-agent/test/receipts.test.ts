import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import test from "node:test";

import { LocalScreenshotArtifactSink } from "../src/index.js";

test("materializes a temporary screenshot as a private durable artifact", async () => {
  const root = await mkdtemp(join(tmpdir(), "iphone-artifact-test-"));
  const source = join(root, "temporary-frame.png");
  const directory = join(root, "captures");
  await writeFile(source, "frame-bytes");
  const sink = new LocalScreenshotArtifactSink(directory);

  const artifact = await sink.writeScreenshot({
    receiptId: "run:test",
    stepId: "capture:top",
    label: "About / Top",
    observation: {
      capturedAt: "2026-08-23T12:00:00.000Z",
      screenshotRef: source
    }
  });

  assert.equal(await readFile(artifact.reference, "utf8"), "frame-bytes");
  assert.equal((await stat(artifact.reference)).mode & 0o777, 0o600);
  assert.match(artifact.reference, /run-test\/capture-top-About-Top\.png$/);
  assert.equal(artifact.mediaType, "image/png");
});

test("artifact names cannot traverse outside the configured directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "iphone-artifact-boundary-"));
  const source = join(root, "temporary-frame.png");
  const directory = join(root, "captures");
  await writeFile(source, "frame-bytes");

  const artifact = await new LocalScreenshotArtifactSink(directory).writeScreenshot({
    receiptId: "..",
    stepId: "../outside",
    label: "../../evidence",
    observation: { capturedAt: "2026-08-23T12:00:00.000Z", screenshotRef: source }
  });

  const storedRelative = relative(directory, artifact.reference);
  assert.equal(storedRelative.startsWith(".."), false);
  assert.equal(storedRelative.split("/")[0], "capture");
});
