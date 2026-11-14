/**
 * Parameterized, read-only SQL queries matching the generic PostgreSQL platform schema.
 * Operates on:
 *   - public.items / public.items_with_totals
 *   - public.leads
 *   - public.channels
 */
import type { Pool } from "../core/db.js";
import type { IndexSource, SourceRow } from "../core/search/vector-index.js";

const ITEM_SUMMARY_COLS = `
  id, sku, name, category, condition, status, platform, quantity,
  cost_basis, list_price, sold_price, sold_date,
  total_cost_basis, total_revenue, net_profit, updated_at`;

const ITEM_DETAIL_COLS = `${ITEM_SUMMARY_COLS}, notes, metadata, created_at`;

export type Row = Record<string, unknown>;

export interface ItemFilters {
  status?: string | undefined;
  category?: string | undefined;
}

function filterSql(f: ItemFilters, params: unknown[]): string[] {
  const where: string[] = [];
  if (f.status !== undefined) {
    params.push(f.status);
    where.push(`lower(status) = lower($${params.length})`);
  }
  if (f.category !== undefined) {
    params.push(f.category);
    where.push(`lower(category) = lower($${params.length})`);
  }
  return where;
}

/** Keyset pagination on id. */
export async function listItems(pool: Pool, f: ItemFilters, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1", ...filterSql(f, params)];
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select ${ITEM_SUMMARY_COLS} from public.items_with_totals where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function getItem(pool: Pool, by: { id?: number | undefined; sku?: string | undefined }) {
  const [col, val] = by.id !== undefined ? ["id", by.id] : ["sku", by.sku];
  const r = await pool.query<Row>(
    `select ${ITEM_DETAIL_COLS} from public.items_with_totals where ${col} = $1`,
    [val],
  );
  return r.rows[0] ?? null;
}

export const GROUP_COLUMNS = {
  status: "status",
  category: "category",
  platform: "platform",
  condition: "condition",
} as const;
export type GroupBy = keyof typeof GROUP_COLUMNS;

export async function summarizeItems(pool: Pool, groupBy: GroupBy, f: ItemFilters) {
  const params: unknown[] = [];
  const where = filterSql(f, params);
  const col = GROUP_COLUMNS[groupBy];
  const r = await pool.query<Row>(
    `select nullif(${col}, '') as key, count(*)::int as count,
            coalesce(sum(total_cost_basis), 0) as total_cost_basis,
            coalesce(sum(total_revenue), 0) as total_revenue,
            coalesce(sum(net_profit) filter (where status = 'sold'), 0) as realized_net_profit
       from public.items_with_totals
      ${where.length ? `where ${where.join(" and ")}` : ""}
      group by 1 order by count(*) desc, 1 nulls last`,
    params,
  );
  return r.rows;
}

export async function listLeads(pool: Pool, stage: string | undefined, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1"];
  if (stage !== undefined) {
    params.push(stage);
    where.push(`lower(stage) = lower($${params.length})`);
  }
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select id, title, contact, stage, target_value, offer_value, source, notes, metadata, updated_at
       from public.leads where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function listChannels(pool: Pool, activeOnly: boolean, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1"];
  if (activeOnly) where.push(`active is true`);
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select id, name, type, fee_pct, active, notes, metadata, updated_at
       from public.channels where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function itemsByIds(pool: Pool, ids: number[]) {
  if (ids.length === 0) return [];
  const r = await pool.query<Row>(
    `select ${ITEM_SUMMARY_COLS} from public.items_with_totals where id = any($1::int[])`,
    [ids],
  );
  return r.rows;
}

/** Vector search source for generic items */
export function itemIndexSource(pool: Pool): IndexSource {
  const ts = `coalesce(updated_at, created_at, 'epoch'::timestamptz)`;
  return {
    async rowsAfter(after, limit): Promise<SourceRow[]> {
      const r = await pool.query<SourceRow>(
        `select id, ${ts}::text as updated_at,
                concat_ws(' | ', name, 'sku: ' || sku, 'category: ' || coalesce(category, ''),
                          'status: ' || status, 'condition: ' || coalesce(condition, ''),
                          'notes: ' || coalesce(notes, '')) as text
           from public.items
          where $1::timestamptz is null or (${ts}, id) > ($1::timestamptz, $2::int)
          order by ${ts}, id
          limit $3`,
        [after?.updated_at ?? null, after?.id ?? 0, limit],
      );
      return r.rows;
    },
  };
}
