#!/usr/bin/env node
// Validate INSTALL.json against INSTALL.schema.json (JSON Schema 2020-12, ajv) plus a few checks a
// schema cannot express: unique ids, compilable regexes, no obvious secret-printing commands.
//   node deploy/scripts/validate-install-guide.mjs [INSTALL.json] [INSTALL.schema.json]
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const guidePath = process.argv[2] || join(root, "INSTALL.json");
const schemaPath = process.argv[3] || join(root, "INSTALL.schema.json");
const guide = JSON.parse(readFileSync(guidePath, "utf8"));
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: false });
const validate = ajv.compile(schema);
const errors = [];
if (!validate(guide)) for (const e of validate.errors) errors.push(`schema: ${e.instancePath || "/"} ${e.message}`);

const all = [...(guide.prerequisites || []), ...(guide.steps || []), ...(guide.post_install_verification || []), ...(guide.uninstall || [])];
const seen = new Set();
for (const s of all) {
  if (seen.has(s.id)) errors.push(`duplicate id ${s.id}`);
  seen.add(s.id);
  for (const ex of [s.expect, s.verify?.expect].filter(Boolean)) {
    if (ex.output_matches) try { new RegExp(ex.output_matches, "m"); } catch (e) { errors.push(`${s.id}: bad regex: ${e.message}`); }
  }
  for (const cmd of [s.run, s.check, s.verify?.run].filter(Boolean)) {
    if (/\bcat\s+\.env\b|docker compose config(?!\s+(-q|--services))|printenv|\benv\s*$/.test(cmd)) errors.push(`${s.id}: command may print secrets: ${cmd}`);
    if (/\bgit push\b/.test(cmd)) errors.push(`${s.id}: git push is not allowed`);
  }
}
if (errors.length) { console.error(errors.join("\n")); console.error(`INVALID: ${errors.length} problem(s)`); process.exit(1); }
console.log(`VALID: ${guidePath} (${guide.steps.length} steps, ${guide.post_install_verification.length} checks, ${guide.uninstall.length} uninstall steps)`);
