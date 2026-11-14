-- Generic Platform Schema for Docker PostgreSQL: tables, views, keys, and indexes.
-- Stripped of all personal data, specific device identifiers, or proprietary fields.
-- Applied at first boot by deploy/initdb/02-schemas.sh as app_owner.

-- 1. Generic Inventory / Items table
CREATE TABLE IF NOT EXISTS public.items (
    id integer NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    sku text NOT NULL UNIQUE,
    name text NOT NULL,
    category text,
    condition text,
    status text NOT NULL DEFAULT 'active',
    cost_basis numeric(12,2) NOT NULL DEFAULT 0.00,
    list_price numeric(12,2),
    sold_price numeric(12,2),
    sold_date date,
    quantity integer NOT NULL DEFAULT 1,
    platform text,
    notes text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS items_status_idx ON public.items (status);
CREATE INDEX IF NOT EXISTS items_category_idx ON public.items (category);
CREATE INDEX IF NOT EXISTS items_updated_at_idx ON public.items (updated_at);

-- 2. Items with Calculated Totals view
CREATE OR REPLACE VIEW public.items_with_totals AS
SELECT
    id,
    sku,
    name,
    category,
    condition,
    status,
    cost_basis,
    list_price,
    sold_price,
    sold_date,
    quantity,
    platform,
    notes,
    metadata,
    created_at,
    updated_at,
    (cost_basis * quantity) AS total_cost_basis,
    COALESCE(sold_price * quantity, 0.00) AS total_revenue,
    CASE
        WHEN status = 'sold' THEN (COALESCE(sold_price, 0.00) - cost_basis) * quantity
        ELSE -(cost_basis * quantity)
    END AS net_profit
FROM public.items;

-- 3. Generic Leads / Opportunities table
CREATE TABLE IF NOT EXISTS public.leads (
    id integer NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    title text NOT NULL,
    contact text,
    stage text NOT NULL DEFAULT 'new',
    target_value numeric(12,2),
    offer_value numeric(12,2),
    source text,
    notes text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS leads_stage_idx ON public.leads (stage);

-- 4. Generic Sales Channels / Profiles table
CREATE TABLE IF NOT EXISTS public.channels (
    id integer NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name text NOT NULL,
    type text,
    fee_pct numeric(5,2) NOT NULL DEFAULT 0.00,
    active boolean NOT NULL DEFAULT true,
    notes text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS channels_active_idx ON public.channels (active);
