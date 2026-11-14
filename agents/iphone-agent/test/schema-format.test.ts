import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { checkSchemaFormat, updateSchemaFormatLock } from "../scripts/check-schema-format.mjs";

const packageRoot = fileURLToPath(new URL("..", import.meta.url));

test("published schemas match their reviewed formatting fingerprints", async () => {
  const files = await checkSchemaFormat(packageRoot);

  assert.deepEqual(files, ["schemas/command.schema.json", "schemas/receipt.schema.json"]);
});

test("a parse-and-serialize schema rewrite fails the format check", async () => {
  const directory = await copyFormatFixture();
  const commandPath = join(directory, "schemas", "command.schema.json");
  const command = JSON.parse(await readFile(commandPath, "utf8"));
  await writeFile(commandPath, `${JSON.stringify(command, null, 2)}\n`, "utf8");

  await assert.rejects(
    checkSchemaFormat(directory),
    /command\.schema\.json does not match its reviewed formatting fingerprint/
  );

  await updateSchemaFormatLock(directory);
  assert.deepEqual(await checkSchemaFormat(directory), [
    "schemas/command.schema.json",
    "schemas/receipt.schema.json"
  ]);
});

test("a newly published schema must be added to the format lock", async () => {
  const directory = await copyFormatFixture();
  await writeFile(join(directory, "schemas", "new.schema.json"), "{}\n", "utf8");

  await assert.rejects(checkSchemaFormat(directory), /new\.schema\.json.*accept:schema-format/);
});

async function copyFormatFixture(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "iphone-schema-format-"));
  await mkdir(join(directory, "schemas"), { recursive: true });
  await mkdir(join(directory, "scripts"), { recursive: true });
  for (const relativePath of [
    "schemas/command.schema.json",
    "schemas/receipt.schema.json",
    "scripts/schema-format-lock.json"
  ]) {
    await writeFile(join(directory, relativePath), await readFile(join(packageRoot, relativePath)));
  }
  return directory;
}
