-- Business tables (the owner's flipping inventory) + the connector's search cache. Applied by
-- `./kit up` as the admin login, after the client tables. Safe to re-run. Schema only: NO rows.
--
-- Table shapes come from ~/Developer/ygg-mcp-business deploy/sql/010_business_schema.sql (a
-- schema-only pg_dump of the NocoDB-made tables; nc_* / created_by columns are NocoDB's),
-- rewritten as CREATE ... IF NOT EXISTS so it can run on every start.
-- psql variables (set by scripts/lib.sh): rw_user, ro_user, ui_user.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public."Business" (
    id serial PRIMARY KEY,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    created_by character varying,
    updated_by character varying,
    nc_order numeric,
    nc_row_meta jsonb,
    "UID" text CONSTRAINT business_uid_key UNIQUE,
    "Item" text,
    "Category" text,
    "Condition" text,
    "Acquisition_Date" date,
    "Buy_Price" numeric,
    "Parts_Invested" numeric,
    "Platform" text,
    "IMEI" text,
    "IMEI2" text,
    "IMEI_Status" text,
    "Battery__" bigint,
    "Status" text,
    "Repair_Status" text,
    "Intended_Action" text,
    "Listed_On" text,
    "List_Price" numeric,
    "Sale_Pricing" text,
    "Sold_Date" date,
    "Sold_Price" numeric,
    "Miles" bigint,
    "Notes" text,
    "Images" text,
    "Airtable_Record_ID" text CONSTRAINT business_airtable_record_id_key UNIQUE,
    "Airtable_Created_Time" timestamp without time zone,
    "Linked__Airtable_ids_" text,
    "Images__Airtable_JSON_" text,
    "Check" text,
    "Check_Notes" text,
    "Confirmed" date
);
CREATE INDEX IF NOT EXISTS "Business_order_idx" ON public."Business" (nc_order);

CREATE TABLE IF NOT EXISTS public."Exit Profiles" (
    id serial PRIMARY KEY,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    created_by character varying,
    updated_by character varying,
    nc_order numeric,
    nc_row_meta jsonb,
    "Exit_Name" text,
    "Exit_Type" text,
    "Buyer___Contact" text,
    "Grade_Floor" text,
    "Accepts_Bad_ESN" text,
    "Accepts_No_Power" text,
    "Price_Basis" text,
    "Fees___Costs" text,
    "Turnaround" text,
    "Active" boolean DEFAULT false,
    "Notes" text
);
CREATE INDEX IF NOT EXISTS "Exit Profiles_order_idx" ON public."Exit Profiles" (nc_order);

CREATE TABLE IF NOT EXISTS public."Leads" (
    id serial PRIMARY KEY,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    created_by character varying,
    updated_by character varying,
    nc_order numeric,
    nc_row_meta jsonb,
    "Lead" text,
    "Contact" text,
    "Device" text,
    "Their_Ask" numeric,
    "My_Offer" numeric,
    "Est__Grade" text,
    "Status" text,
    "Next_Touch" date,
    "Source" text,
    "Notes" text,
    "Business_id" integer CONSTRAINT "fk_Business_Leads_1rlf498fez" REFERENCES public."Business"(id)
);
CREATE INDEX IF NOT EXISTS "Leads_order_idx" ON public."Leads" (nc_order);
CREATE INDEX IF NOT EXISTS "fk_Business_Leads_iox1oott5l" ON public."Leads" ("Business_id");

CREATE TABLE IF NOT EXISTS public."Phone Grades" (
    id serial PRIMARY KEY,
    created_at timestamp without time zone,
    updated_at timestamp without time zone,
    created_by character varying,
    updated_by character varying,
    nc_order numeric,
    nc_row_meta jsonb,
    "Grade_Label" text,
    "Grade" text,
    "Phone_Model" text,
    "Summary" text,
    "Concerns" text,
    "Grade_JSON" text,
    "Graded_At" timestamp without time zone,
    "Bot_Grade_ID" bigint,
    "Telegram_User_ID" bigint,
    "Source" text
);
CREATE INDEX IF NOT EXISTS "Phone Grades_order_idx" ON public."Phone Grades" (nc_order);

CREATE OR REPLACE VIEW public.business_with_totals AS
 SELECT id, created_at, updated_at, created_by, updated_by, nc_order, nc_row_meta,
    "UID", "Item", "Category", "Condition", "Acquisition_Date", "Buy_Price", "Parts_Invested",
    "Platform", "IMEI", "IMEI2", "IMEI_Status", "Battery__", "Status", "Repair_Status",
    "Intended_Action", "Listed_On", "List_Price", "Sale_Pricing", "Sold_Date", "Sold_Price",
    "Miles", "Notes", "Images", "Airtable_Record_ID", "Airtable_Created_Time",
    "Linked__Airtable_ids_", "Images__Airtable_JSON_",
    (COALESCE("Buy_Price", 0::numeric) + COALESCE("Parts_Invested", 0::numeric)) AS "Total_Cost_Basis",
    ((COALESCE("Sold_Price", 0::numeric) - COALESCE("Buy_Price", 0::numeric)) - COALESCE("Parts_Invested", 0::numeric)) AS "Net_Profit"
   FROM public."Business" b;

-- Every change to a business row (from NocoDB or the admin) gets a write_log receipt.
DROP TRIGGER IF EXISTS trg_kit_write_log ON public."Business";
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON public."Business" FOR EACH ROW EXECUTE FUNCTION kit_write_log();
DROP TRIGGER IF EXISTS trg_kit_write_log ON public."Leads";
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON public."Leads" FOR EACH ROW EXECUTE FUNCTION kit_write_log();
DROP TRIGGER IF EXISTS trg_kit_write_log ON public."Exit Profiles";
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON public."Exit Profiles" FOR EACH ROW EXECUTE FUNCTION kit_write_log();
DROP TRIGGER IF EXISTS trg_kit_write_log ON public."Phone Grades";
CREATE TRIGGER trg_kit_write_log AFTER INSERT OR UPDATE OR DELETE ON public."Phone Grades" FOR EACH ROW EXECUTE FUNCTION kit_write_log();

-- Who may do what. The AI (both logins) may only READ business data. NocoDB (ui) may read,
-- add and edit, like the client tables. Nobody but the admin may delete.
REVOKE ALL ON public."Business", public."Leads", public."Exit Profiles", public."Phone Grades", public.business_with_totals
  FROM PUBLIC, :"rw_user", :"ro_user", :"ui_user";
GRANT SELECT ON public."Business", public."Leads", public."Exit Profiles", public."Phone Grades", public.business_with_totals
  TO :"rw_user", :"ro_user", :"ui_user";
GRANT INSERT, UPDATE ON public."Business", public."Leads", public."Exit Profiles", public."Phone Grades" TO :"ui_user";
GRANT USAGE ON SEQUENCE public."Business_id_seq", public."Leads_id_seq", public."Exit Profiles_id_seq", public."Phone Grades_id_seq" TO :"ui_user";

-- Search cache for business_search_items (derived data, rebuildable; NOT receipts).
-- Vectors are stored as real[] and ranked inside the connector (pgvector is not needed).
CREATE SCHEMA IF NOT EXISTS mcp;
CREATE TABLE IF NOT EXISTS mcp.search_vectors (
  item_id      bigint      NOT NULL,
  model        text        NOT NULL,
  embedding    real[]      NOT NULL,
  content_hash text        NOT NULL,
  updated_at   timestamp   NOT NULL,
  indexed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, model)
);
CREATE TABLE IF NOT EXISTS mcp.index_state (
  model           text        PRIMARY KEY,
  last_updated_at timestamp   NOT NULL,
  last_id         bigint      NOT NULL,
  synced_at       timestamptz NOT NULL DEFAULT now()
);
-- Only the AI's read/write login keeps the cache up to date; the read-only login stays read-only.
REVOKE ALL ON SCHEMA mcp FROM PUBLIC;
REVOKE ALL ON mcp.search_vectors, mcp.index_state FROM PUBLIC, :"rw_user", :"ro_user", :"ui_user";
GRANT USAGE ON SCHEMA mcp TO :"rw_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON mcp.search_vectors, mcp.index_state TO :"rw_user";

COMMIT;
