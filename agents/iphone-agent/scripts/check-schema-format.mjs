#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lockRelativePath = "scripts/schema-format-lock.json";

export async function checkSchemaFormat(root = packageRoot) {
  const canonicalRoot = resolve(root);
  const manifest = await readManifest(canonicalRoot);
  const schemaFiles = await discoverSchemaFiles(canonicalRoot);
  const lockedFiles = Object.keys(manifest.files).sort();

  if (JSON.stringify(schemaFiles) !== JSON.stringify(lockedFiles)) {
    throw new Error(
      `Schema format lock covers ${lockedFiles.join(", ") || "no files"}, but schemas contains ` +
      `${schemaFiles.join(", ") || "no files"}. Review the schema change, then run npm run accept:schema-format.`
    );
  }

  const mismatches = [];
  for (const relativePath of schemaFiles) {
    const source = await readFile(schemaPath(canonicalRoot, relativePath));
    try {
      JSON.parse(source.toString("utf8"));
    } catch (error) {
      const cause = error instanceof Error ? error.message : String(error);
      throw new Error(`${relativePath} is not valid JSON: ${cause}`);
    }
    const actual = digest(source);
    if (actual !== manifest.files[relativePath]) mismatches.push(relativePath);
  }

  if (mismatches.length > 0) {
    throw new Error(
      `${mismatches.join(", ")} does not match its reviewed formatting fingerprint. ` +
      "Revert mechanical reformatting and make the schema edit minimally. After reviewing the diff, " +
      "run npm run accept:schema-format to record the new canonical bytes."
    );
  }

  return schemaFiles;
}

export async function updateSchemaFormatLock(root = packageRoot) {
  const canonicalRoot = resolve(root);
  const schemaFiles = await discoverSchemaFiles(canonicalRoot);
  const files = {};
  for (const relativePath of schemaFiles) {
    const source = await readFile(schemaPath(canonicalRoot, relativePath));
    try {
      JSON.parse(source.toString("utf8"));
    } catch (error) {
      const cause = error instanceof Error ? error.message : String(error);
      throw new Error(`${relativePath} is not valid JSON: ${cause}`);
    }
    files[relativePath] = digest(source);
  }
  const manifest = { version: 1, algorithm: "sha256", files };
  await writeFile(join(canonicalRoot, lockRelativePath), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  return schemaFiles;
}

async function readManifest(root) {
  const path = join(root, lockRelativePath);
  let parsed;
  try {
    parsed = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    const cause = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read ${lockRelativePath}: ${cause}`);
  }
  if (
    parsed?.version !== 1 ||
    parsed?.algorithm !== "sha256" ||
    typeof parsed?.files !== "object" ||
    parsed.files === null ||
    Array.isArray(parsed.files) ||
    Object.values(parsed.files).some(
      (value) => typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)
    )
  ) {
    throw new Error(`${lockRelativePath} is invalid`);
  }
  return parsed;
}

async function discoverSchemaFiles(root) {
  const entries = await readdir(join(root, "schemas"), { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".schema.json"))
    .map((entry) => `schemas/${entry.name}`)
    .sort();
}

function schemaPath(root, relativePath) {
  const path = resolve(root, relativePath);
  const schemaRoot = resolve(root, "schemas");
  const fromSchemaRoot = relative(schemaRoot, path);
  if (
    !path.startsWith(`${schemaRoot}${sep}`) ||
    fromSchemaRoot === ".." ||
    fromSchemaRoot.startsWith(`..${sep}`) ||
    isAbsolute(fromSchemaRoot)
  ) {
    throw new Error(`Schema format lock contains an unsafe path: ${relativePath}`);
  }
  return path;
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some((argument) => argument !== "--update") || args.length > 1) {
      throw new Error("usage: check-schema-format.mjs [--update]");
    }
    const update = args[0] === "--update";
    const files = update ? await updateSchemaFormatLock() : await checkSchemaFormat();
    process.stdout.write(
      update
        ? `Recorded reviewed schema formatting for ${files.length} files.\n`
        : `Schema formatting matches reviewed fingerprints (${files.length} files).\n`
    );
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
