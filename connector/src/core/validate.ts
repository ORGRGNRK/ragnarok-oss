/**
 * Input validation. Zod schemas are the single source of truth: they validate
 * arguments at call time and are converted to JSON Schema for tools/list.
 */
import { z } from "zod";
import { ToolError } from "./errors.js";

export { z };

/** Validate tool arguments; failures become actionable invalid_argument ToolErrors. */
export function validateArgs<S extends z.ZodType>(tool: string, schema: S, args: unknown): z.infer<S> {
  const parsed = schema.safeParse(args ?? {});
  if (parsed.success) return parsed.data;
  const issues = parsed.error.issues.map((i) => {
    const path = i.path.length ? i.path.join(".") : "(arguments)";
    return `${path}: ${i.message}`;
  });
  throw new ToolError({
    code: "invalid_argument",
    what: `${tool} rejected its arguments`,
    why: issues.join("; "),
    retry_safe: true,
    fix: "correct the listed argument(s) to match the tool's inputSchema and call again",
  });
}

/** JSON Schema (draft 2020-12 compatible object) for a zod object schema. */
export function toInputSchema(schema: z.ZodType): { type: "object"; [k: string]: unknown } {
  const js = z.toJSONSchema(schema, { io: "input" }) as Record<string, unknown>;
  delete js.$schema;
  if (js.type !== "object") throw new Error("tool input schemas must be objects");
  return js as { type: "object"; [k: string]: unknown };
}
