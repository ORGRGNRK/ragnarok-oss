/**
 * All SQL for the Business layer. Every query is parameterized and read-only;
 * column/identifier choices come from fixed whitelists, never from input.
 */
import type { Pool } from "../core/db.js";
import type { IndexSource, SourceRow } from "../core/search/vector-index.js";

const ITEM_SUMMARY_COLS = `
  id, "UID" as uid, "Item" as item, "Category" as category, "Condition" as condition,
  "Status" as status, "Platform" as platform, "Buy_Price" as buy_price,
  "Parts_Invested" as parts_invested, "Total_Cost_Basis" as total_cost_basis,
  "List_Price" as list_price, "Sold_Price" as sold_price, "Sold_Date" as sold_date,
  "Net_Profit" as net_profit, "Acquisition_Date" as acquisition_date, updated_at`;

const ITEM_DETAIL_COLS = `${ITEM_SUMMARY_COLS},
  "Repair_Status" as repair_status, "Intended_Action" as intended_action,
  "Listed_On" as listed_on, "Sale_Pricing" as sale_pricing, "IMEI_Status" as imei_status,
  right("IMEI", 4) as imei_last4, right("IMEI2", 4) as imei2_last4,
  "Battery__" as battery_pct, "Miles" as miles, "Notes" as notes, created_at`;

/** Columns the view does not carry; read from the base table by id. */
const ITEM_CHECK_COLS = `
  (select b."Check" from public."Business" b where b.id = v.id) as check_flag,
  (select b."Check_Notes" from public."Business" b where b.id = v.id) as check_notes,
  (select b."Confirmed" from public."Business" b where b.id = v.id) as confirmed`;

export type Row = Record<string, unknown>;

export interface ItemFilters {
  status?: string | undefined;
  category?: string | undefined;
}

function filterSql(f: ItemFilters, params: unknown[]): string[] {
  const where: string[] = [];
  if (f.status !== undefined) {
    params.push(f.status);
    where.push(`lower("Status") = lower($${params.length})`);
  }
  if (f.category !== undefined) {
    params.push(f.category);
    where.push(`lower("Category") = lower($${params.length})`);
  }
  return where;
}

/** Keyset page on id. Fetches limit+1 rows to know whether another page exists. */
export async function listItems(pool: Pool, f: ItemFilters, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1", ...filterSql(f, params)];
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select ${ITEM_SUMMARY_COLS} from public.business_with_totals where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function getItem(pool: Pool, by: { id?: number | undefined; uid?: string | undefined }) {
  const [col, val] = by.id !== undefined ? ["id", by.id] : ['"UID"', by.uid];
  const r = await pool.query<Row>(
    `select ${ITEM_DETAIL_COLS}, ${ITEM_CHECK_COLS} from public.business_with_totals v where v.${col} = $1`,
    [val],
  );
  return r.rows[0] ?? null;
}

export const GROUP_COLUMNS = {
  status: '"Status"',
  category: '"Category"',
  platform: '"Platform"',
  condition: '"Condition"',
} as const;
export type GroupBy = keyof typeof GROUP_COLUMNS;

export async function summarizeItems(pool: Pool, groupBy: GroupBy, f: ItemFilters) {
  const params: unknown[] = [];
  const where = filterSql(f, params);
  const col = GROUP_COLUMNS[groupBy];
  const r = await pool.query<Row>(
    `select nullif(${col}, '') as key, count(*)::int as count,
            coalesce(sum("Buy_Price"), 0) as buy_total,
            coalesce(sum("Parts_Invested"), 0) as parts_total,
            coalesce(sum("Sold_Price"), 0) as sold_total,
            coalesce(sum("Net_Profit") filter (where "Sold_Price" is not null), 0) as realized_net_profit
       from public.business_with_totals
      ${where.length ? `where ${where.join(" and ")}` : ""}
      group by 1 order by count(*) desc, 1 nulls last`,
    params,
  );
  return r.rows;
}

export async function listLeads(pool: Pool, status: string | undefined, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1"];
  if (status !== undefined) {
    params.push(status);
    where.push(`lower("Status") = lower($${params.length})`);
  }
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select id, "Lead" as lead, "Contact" as contact, "Device" as device, "Their_Ask" as their_ask,
            "My_Offer" as my_offer, "Est__Grade" as est_grade, "Status" as status,
            "Next_Touch" as next_touch, "Source" as source, "Notes" as notes,
            "Business_id" as item_id, updated_at
       from public."Leads" where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function listExitProfiles(pool: Pool, activeOnly: boolean, afterId: number, limit: number) {
  const params: unknown[] = [afterId];
  const where = ["id > $1"];
  if (activeOnly) where.push(`"Active" is true`);
  params.push(limit + 1);
  const r = await pool.query<Row>(
    `select id, "Exit_Name" as exit_name, "Exit_Type" as exit_type, "Buyer___Contact" as buyer_contact,
            "Grade_Floor" as grade_floor, "Accepts_Bad_ESN" as accepts_bad_esn,
            "Accepts_No_Power" as accepts_no_power, "Price_Basis" as price_basis,
            "Fees___Costs" as fees_costs, "Turnaround" as turnaround, "Active" as active,
            "Notes" as notes, updated_at
       from public."Exit Profiles" where ${where.join(" and ")} order by id limit $${params.length}`,
    params,
  );
  return { rows: r.rows.slice(0, limit), more: r.rows.length > limit };
}

export async function itemsByIds(pool: Pool, ids: number[]) {
  if (ids.length === 0) return [];
  const r = await pool.query<Row>(
    `select ${ITEM_SUMMARY_COLS} from public.business_with_totals where id = any($1::int[])`,
    [ids],
  );
  return r.rows;
}

/**
 * Search source: Business rows in (updated_at, id) order. The embedded text
 * deliberately excludes IMEI and other identifiers so they never leave the box.
 */
export function itemIndexSource(pool: Pool): IndexSource {
  const ts = `coalesce(updated_at, created_at, 'epoch'::timestamp)`;
  return {
    async rowsAfter(after, limit): Promise<SourceRow[]> {
      const r = await pool.query<SourceRow>(
        `select id, ${ts}::text as updated_at,
                concat_ws(' | ', "Item", 'category: ' || "Category", 'status: ' || "Status",
                          'condition: ' || nullif("Condition", ''), 'platform: ' || nullif("Platform", ''),
                          'notes: ' || nullif("Notes", '')) as text
           from public."Business"
          where $1::timestamp is null or (${ts}, id) > ($1::timestamp, $2::int)
          order by ${ts}, id
          limit $3`,
        [after?.updated_at ?? null, after?.id ?? 0, limit],
      );
      return r.rows;
    },
  };
}
