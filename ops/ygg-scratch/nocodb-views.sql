-- Read-only views so NocoDB (base "Ygg Receipts", which only sees schema public) shows the live AI receipts.
-- Apply by hand as postgres (not part of receipt.mjs migrate, which runs as ygg_app): docker exec -i ygg-scratch-pg psql -U postgres -d ygg_receipts < nocodb-views.sql
create or replace view public."AI Receipts" as select * from mac.receipts order by seq desc;
grant select on public."AI Receipts" to ygg_app, ygg_read;
create or replace view public."AI Receipts Chain Check" as select * from mac.verify();
grant select on public."AI Receipts Chain Check" to ygg_app, ygg_read;
