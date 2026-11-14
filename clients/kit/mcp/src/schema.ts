// client/schema.json: the ONE file that describes a client's tables. Everything else (the
// database tables, the AI's tools, validation, the test) is driven from it.
import { readFileSync } from "node:fs";

export type FieldType =
  | "text" | "long_text" | "email" | "url" | "integer" | "number" | "money"
  | "boolean" | "date" | "datetime" | "select";
export const FIELD_TYPES: FieldType[] = ["text", "long_text", "email", "url", "integer", "number", "money", "boolean", "date", "datetime", "select"];
const TEXTY: FieldType[] = ["text", "long_text", "email", "url", "select"];

export interface Field {
  name: string;            // what people and the AI see, e.g. "Unit Price"
  column: string;          // the Postgres column, e.g. unit_price (made from name if left out)
  type: FieldType;
  required: boolean;
  unique: boolean;
  writable: boolean;       // false = the AI can read it but never set it
  choices?: string[];      // select only
  default?: unknown;
  max_length?: number;
  description?: string;
}
export interface Table { name: string; sql_name: string; description?: string; fields: Field[] }
export interface Schema { client: string; description?: string; tables: Table[] }

/** A rule said no. Nothing is written. */
export class Refusal extends Error {}

const SQL_NAME = /^[a-z][a-z0-9_]{0,62}$/;
const RESERVED = new Set(["id", "created_at", "updated_at"]);
const KIT_TABLES = new Set(["write_log", "access_log", "archive", "approvals", "kit_tables"]);
export const slug = (s: string) => s.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").replace(/^(\d)/, "f_$1");

export function parseSchema(raw: unknown): Schema {
  const bad = (m: string): never => { throw new Error(`schema.json: ${m}`); };
  const o = raw as any;
  if (!o || typeof o !== "object") bad("must be a JSON object");
  if (typeof o.client !== "string" || !o.client.trim()) bad('needs "client": "Client name"');
  if (!Array.isArray(o.tables) || o.tables.length === 0) bad('needs "tables": [ ... ] with at least one table');
  const tableNames = new Set<string>(); const sqlNames = new Set<string>();
  const tables: Table[] = o.tables.map((t: any, ti: number) => {
    const where = `tables[${ti}]`;
    if (typeof t?.name !== "string" || !t.name.trim()) bad(`${where} needs a "name"`);
    const sql_name = t.sql_name ?? slug(t.name);
    if (!SQL_NAME.test(sql_name)) bad(`${where}.sql_name "${sql_name}" must be lowercase letters, digits, _`);
    if (KIT_TABLES.has(sql_name)) bad(`${where}: "${sql_name}" is a kit table name, pick another`);
    if (tableNames.has(t.name.toLowerCase()) || sqlNames.has(sql_name)) bad(`${where}: duplicate table "${t.name}"`);
    tableNames.add(t.name.toLowerCase()); sqlNames.add(sql_name);
    if (!Array.isArray(t.fields) || t.fields.length === 0) bad(`${where} needs "fields": [ ... ]`);
    const fnames = new Set<string>(["id"]); const cols = new Set<string>();
    const fields: Field[] = t.fields.map((f: any, fi: number) => {
      const fw = `${where}.fields[${fi}]`;
      if (typeof f?.name !== "string" || !f.name.trim()) bad(`${fw} needs a "name"`);
      const column = f.column ?? slug(f.name);
      if (!SQL_NAME.test(column)) bad(`${fw}.column "${column}" must be lowercase letters, digits, _`);
      if (RESERVED.has(column)) bad(`${fw}: "${column}" is reserved (every table already has id, created_at, updated_at)`);
      if (fnames.has(f.name.toLowerCase()) || cols.has(column)) bad(`${fw}: duplicate field "${f.name}"`);
      fnames.add(f.name.toLowerCase()); cols.add(column);
      const type = (f.type ?? "text") as FieldType;
      if (!FIELD_TYPES.includes(type)) bad(`${fw}: type "${f.type}" must be one of ${FIELD_TYPES.join(", ")}`);
      if (type === "select" && (!Array.isArray(f.choices) || f.choices.length === 0 || !f.choices.every((c: unknown) => typeof c === "string" && c.trim())))
        bad(`${fw}: a select field needs "choices": ["A", "B"]`);
      const field: Field = {
        name: f.name.trim(), column, type,
        required: f.required === true, unique: f.unique === true, writable: f.writable !== false,
        choices: type === "select" ? f.choices.map((c: string) => c.trim()) : undefined,
        default: f.default, max_length: f.max_length, description: f.description,
      };
      if (f.default !== undefined && f.default !== null) {
        try { field.default = coerce(field, f.default); } catch (e) { bad(`${fw}: default ${JSON.stringify(f.default)} is not valid: ${(e as Error).message}`); }
      }
      return field;
    });
    return { name: t.name.trim(), sql_name, description: t.description, fields };
  });
  return { client: o.client.trim(), description: o.description, tables };
}

let cached: Schema | undefined;
export function loadSchema(path = process.env.KIT_SCHEMA || "client/schema.json"): Schema {
  if (!cached) cached = parseSchema(JSON.parse(readFileSync(path, "utf8")));
  return cached;
}

export function findTable(s: Schema, name: string): Table {
  const n = String(name ?? "").trim().toLowerCase();
  const t = s.tables.find((x) => x.name.toLowerCase() === n || x.sql_name === n);
  if (!t) throw new Refusal(`no table called "${name}". Tables: ${s.tables.map((x) => x.name).join(", ")}`);
  return t;
}

export function findField(t: Table, name: string): Field {
  const n = String(name).trim().toLowerCase();
  const f = t.fields.find((x) => x.name.toLowerCase() === n || x.column === n);
  if (!f) throw new Refusal(`table ${t.name} has no field "${name}". Fields: ${t.fields.map((x) => x.name).join(", ")}`);
  return f;
}

export const isTexty = (f: Field) => TEXTY.includes(f.type);

/** Turn what the AI sent into the value Postgres should store, or refuse with a clear reason. */
export function coerce(f: Field, v: unknown): unknown {
  if (v === null || v === undefined || (typeof v === "string" && v.trim() === "" && f.type !== "text" && f.type !== "long_text")) {
    if (f.required) throw new Refusal(`${f.name} is required and can't be empty`);
    return null;
  }
  const no = (why: string): never => { throw new Refusal(`${f.name}: ${JSON.stringify(v)} ${why}`); };
  switch (f.type) {
    case "text": case "long_text": case "email": case "url": {
      if (typeof v !== "string" && typeof v !== "number") no("must be text");
      const s = String(v).trim();
      if (f.required && s === "") no("is required and can't be empty");
      const max = f.max_length ?? (f.type === "long_text" ? 20000 : 500);
      if (s.length > max) no(`is longer than ${max} characters`);
      if (f.type === "email" && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s)) no("is not an email address");
      if (f.type === "url" && !/^https?:\/\/\S+$/i.test(s)) no("is not a web address (http:// or https://)");
      return s;
    }
    case "select": {
      const s = String(v).trim();
      const hit = f.choices!.find((c) => c.toLowerCase() === s.toLowerCase());
      if (!hit) no(`is not one of: ${f.choices!.join(", ")}`);
      return hit;
    }
    case "integer": {
      const n = typeof v === "number" ? v : typeof v === "string" && /^-?\d+$/.test(v.trim()) ? Number(v) : NaN;
      if (!Number.isSafeInteger(n) || Math.abs(n) > 2147483647) no("must be a whole number");
      return n;
    }
    case "number": case "money": {
      const n = typeof v === "number" ? v : typeof v === "string" && /^-?\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : NaN;
      if (!Number.isFinite(n)) no("must be a number");
      if (f.type === "money") {
        if (!/^-?\d+(\.\d{1,2})?$/.test(String(n))) no("must have at most 2 decimal places");
        if (Math.abs(n) >= 1e10) no("is too large");
      }
      return n;
    }
    case "boolean": {
      if (typeof v === "boolean") return v;
      const s = String(v).trim().toLowerCase();
      if (["true", "yes", "1"].includes(s)) return true;
      if (["false", "no", "0"].includes(s)) return false;
      return no("must be true or false");
    }
    case "date": {
      const s = String(v).trim();
      const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
      const d = m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])) : null;
      if (!m || !d || d.getUTCFullYear() !== +m[1] || d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) no("must be a date like 2026-10-27");
      return s;
    }
    case "datetime": {
      const s = String(v).trim();
      const t = Date.parse(s);
      if (!/^\d{4}-\d{2}-\d{2}T/.test(s) || Number.isNaN(t)) no("must be a date-time like 2026-10-27T14:30:00-07:00");
      return new Date(t).toISOString();
    }
  }
}

/** Make a database value comparable with what we meant to store (for the read-back check). */
export function comparable(f: Field, v: unknown): unknown {
  if (v === null || v === undefined) return null;
  switch (f.type) {
    case "integer": case "number": case "money": return Number(v);
    case "boolean": return v === true || v === "t" || v === "true";
    case "datetime": return new Date(v as string).getTime();
    default: return String(v);
  }
}

/** A database row -> { "Id": 3, "Field Name": value, ..., "Created": ..., "Updated": ... } */
export function present(t: Table, row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { Id: Number(row.id) };
  for (const f of t.fields) {
    const v = row[f.column];
    out[f.name] = v === null || v === undefined ? null
      : (f.type === "number" || f.type === "money") ? Number(v)
      : f.type === "datetime" ? new Date(v as string).toISOString()
      : v;
  }
  if (row.created_at) out.Created = new Date(row.created_at as string).toISOString();
  if (row.updated_at) out.Updated = new Date(row.updated_at as string).toISOString();
  return out;
}

// ------------------------------------------------------------------ SQL generation

const qi = (s: string) => `"${s.replace(/"/g, '""')}"`;
export const ql = (v: unknown): string => {
  if (v === null || v === undefined) return "NULL";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  return `'${String(v).replace(/'/g, "''")}'`;
};
const PG_TYPE: Record<FieldType, string> = {
  text: "text", long_text: "text", email: "text", url: "text", select: "text",
  integer: "integer", number: "numeric", money: "numeric(12,2)", boolean: "boolean", date: "date", datetime: "timestamptz",
};

export interface Roles { rw: string; ro: string; ui: string }

/** Idempotent SQL that creates / extends the client's tables and grants. Safe to re-run. */
export function schemaSql(s: Schema, roles: Roles): string {
  const L: string[] = ["-- generated from client/schema.json by `./kit up` (safe to re-run)", "BEGIN;"];
  const R = { rw: qi(roles.rw), ro: qi(roles.ro), ui: qi(roles.ui) };
  for (const t of s.tables) {
    const T = qi(t.sql_name);
    L.push(``, `-- ${t.name}`);
    L.push(`CREATE TABLE IF NOT EXISTS ${T} (id bigserial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());`);
    for (const f of t.fields) {
      const C = qi(f.column);
      L.push(`ALTER TABLE ${T} ADD COLUMN IF NOT EXISTS ${C} ${PG_TYPE[f.type]};`);
      L.push(f.default !== undefined && f.default !== null ? `ALTER TABLE ${T} ALTER COLUMN ${C} SET DEFAULT ${ql(f.default)};` : `ALTER TABLE ${T} ALTER COLUMN ${C} DROP DEFAULT;`);
      L.push(`ALTER TABLE ${T} ALTER COLUMN ${C} ${f.required ? "SET" : "DROP"} NOT NULL;`);
      const ck = qi(`${t.sql_name}_${f.column}_check`.slice(0, 63));
      L.push(`ALTER TABLE ${T} DROP CONSTRAINT IF EXISTS ${ck};`);
      if (f.type === "select") L.push(`ALTER TABLE ${T} ADD CONSTRAINT ${ck} CHECK (${C} IN (${f.choices!.map(ql).join(", ")}));`);
      if (f.type === "email") L.push(`ALTER TABLE ${T} ADD CONSTRAINT ${ck} CHECK (${C} ~ '^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$');`);
      const ux = qi(`${t.sql_name}_${f.column}_key`.slice(0, 63));
      L.push(f.unique ? `CREATE UNIQUE INDEX IF NOT EXISTS ${ux} ON ${T} (${C});` : `DROP INDEX IF EXISTS ${ux};`);
    }
    L.push(`DROP TRIGGER IF EXISTS trg_kit_write_log ON ${T};`);
    L.push(`CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON ${T} FOR EACH ROW EXECUTE FUNCTION kit_write_log();`);
    L.push(`DROP TRIGGER IF EXISTS trg_kit_touch ON ${T};`);
    L.push(`CREATE TRIGGER trg_kit_touch BEFORE UPDATE ON ${T} FOR EACH ROW EXECUTE FUNCTION kit_touch_updated_at();`);
    L.push(`INSERT INTO kit_tables (sql_name, display_name) VALUES (${ql(t.sql_name)}, ${ql(t.name)}) ON CONFLICT (sql_name) DO UPDATE SET display_name = EXCLUDED.display_name;`);
    // the AI (write mode) and NocoDB: read, add, update. Nobody but the admin may DELETE.
    L.push(`REVOKE ALL ON ${T} FROM PUBLIC, ${R.rw}, ${R.ro}, ${R.ui};`);
    // column-level: the AI may only set fields marked writable; NocoDB may set any field.
    // Nobody but the admin can change id / created_at / updated_at.
    const aiCols = t.fields.filter((f) => f.writable).map((f) => qi(f.column)).join(", ");
    const allCols = t.fields.map((f) => qi(f.column)).join(", ");
    L.push(`GRANT SELECT ON ${T} TO ${R.rw}, ${R.ui};`);
    if (aiCols) L.push(`GRANT INSERT (${aiCols}), UPDATE (${aiCols}) ON ${T} TO ${R.rw};`);
    L.push(`GRANT INSERT (${allCols}), UPDATE (${allCols}) ON ${T} TO ${R.ui};`);
    L.push(`GRANT SELECT ON ${T} TO ${R.ro};`);
    L.push(`GRANT USAGE ON SEQUENCE ${qi(t.sql_name + "_id_seq")} TO ${R.rw}, ${R.ui};`);
  }
  L.push(``, `-- kit tables: everyone reads; only database triggers and kit functions write.`);
  L.push(`REVOKE ALL ON write_log, access_log, archive, approvals, kit_tables FROM PUBLIC, ${R.rw}, ${R.ro}, ${R.ui};`);
  L.push(`GRANT SELECT ON write_log, archive, kit_tables, approvals TO ${R.rw}, ${R.ro}, ${R.ui};`);
  L.push(`GRANT SELECT, INSERT ON access_log TO ${R.rw}, ${R.ro};`);
  L.push(`GRANT SELECT ON access_log TO ${R.ui};`);
  L.push(`GRANT EXECUTE ON FUNCTION kit_verify() TO ${R.rw}, ${R.ro}, ${R.ui};`);
  L.push(`GRANT EXECUTE ON FUNCTION kit_request_archive(text, bigint, text, text, int), kit_archive(text, bigint, text, text, text) TO ${R.rw};`);
  L.push(`COMMIT;`);
  return L.join("\n") + "\n";
}

/** Rows from `./kit money load` (money/load.json) as INSERTs. Unlike seeding, tables need not be empty: a row whose
 *  unique key field (the first unique field, e.g. Row Key) is already there is skipped, so loading twice changes nothing. */
export function insertSql(s: Schema, data: Record<string, unknown>, actor: string): string {
  const L: string[] = ["BEGIN;", `SET LOCAL receipt.actor = ${ql(actor)};`];
  for (const [tname, rows] of Object.entries(data ?? {})) {
    if (tname.startsWith("_") || !Array.isArray(rows) || rows.length === 0) continue;
    const t = findTable(s, tname);
    const uk = t.fields.find((f) => f.unique);
    if (!uk) throw new Error(`${t.name} needs a unique field so rows already loaded can be skipped`);
    const T = qi(t.sql_name);
    rows.forEach((r: any, i: number) => {
      const cols: string[] = []; const vals: string[] = [];
      for (const [k, v] of Object.entries(r ?? {})) {
        let f: Field, cv: unknown;
        try { f = findField(t, k); cv = coerce(f, v); } catch (e) { throw new Error(`${t.name}[${i}]: ${(e as Error).message}`); }
        cols.push(qi(f.column)); vals.push(`${ql(cv)}::${PG_TYPE[f.type]}`);
      }
      for (const f of t.fields) if (f.required && f.default == null && !cols.includes(qi(f.column))) throw new Error(`${t.name}[${i}]: ${f.name} is required`);
      L.push(`INSERT INTO ${T} (${cols.join(", ")}) VALUES (${vals.join(", ")}) ON CONFLICT (${qi(uk.column)}) DO NOTHING;`);
    });
  }
  L.push("COMMIT;");
  return L.join("\n") + "\n";
}

/** Seed rows (client/seed.json) as INSERTs. A table is only seeded while it is still empty. */
export function seedSql(s: Schema, seed: Record<string, unknown>): string {
  const L: string[] = ["-- generated from client/seed.json by `./kit seed`", "BEGIN;", "SET LOCAL receipt.actor = 'seed (client/seed.json)';"];
  for (const [tname, rows] of Object.entries(seed ?? {})) {
    if (tname.startsWith("_")) continue;
    const t = findTable(s, tname);
    if (!Array.isArray(rows) || rows.length === 0) continue;
    const T = qi(t.sql_name);
    L.push(``, `-- ${t.name}: ${rows.length} rows (skipped if the table already has data)`);
    L.push(`DO $seed$ BEGIN IF NOT EXISTS (SELECT 1 FROM ${T}) THEN`);
    rows.forEach((r: any, i: number) => {
      const cols: string[] = []; const vals: string[] = [];
      for (const [k, v] of Object.entries(r ?? {})) {
        let f: Field;
        try { f = findField(t, k); } catch (e) { throw new Error(`seed.json ${t.name}[${i}]: ${(e as Error).message}`); }
        let cv: unknown;
        try { cv = coerce(f, v); } catch (e) { throw new Error(`seed.json ${t.name}[${i}]: ${(e as Error).message}`); }
        cols.push(qi(f.column)); vals.push(`${ql(cv)}::${PG_TYPE[f.type]}`);
      }
      for (const f of t.fields) if (f.required && f.default == null && !cols.includes(qi(f.column))) throw new Error(`seed.json ${t.name}[${i}]: ${f.name} is required`);
      L.push(`  INSERT INTO ${T} (${cols.join(", ")}) VALUES (${vals.join(", ")});`);
    });
    L.push(`END IF; END $seed$;`);
  }
  L.push("COMMIT;");
  return L.join("\n") + "\n";
}
