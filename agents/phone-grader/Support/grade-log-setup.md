# PostgreSQL grade log with the existing NocoDB frontend

Status: implementation is ready for deployment; Alexus deployment is NOT verified.
SSH on 2026-11-12 required a Tailscale authentication check. Do not create a second
NocoDB instance merely to make a test green. First identify the owner's existing base
and its business PostgreSQL database after authentication.

1. Back up the business database. Apply `phone_grades.sql` with psql as its owner.
   It creates `phone_grades` and `phone_grade_receipts` without dropping data.
2. Create a dedicated gateway database login. Grant SELECT/INSERT/UPDATE on
   `phone_grades`, INSERT on `phone_grade_receipts`, and USAGE on the receipt
   identity sequence. Do not give it DDL or access to unrelated tables.
3. Install Python 3.11+ and psycopg v3 in an isolated environment on Alexus.
   Run `scripts/grade_log_server.py` as an unprivileged service. Provide
   `PHONE_GRADES_DATABASE_URL` and a random `PHONE_GRADES_TOKEN` of at least
   32 characters through a protected environment file. Never commit either.
   The service listens only on 127.0.0.1:8789 (PORT overrides it).
4. Route a private HTTPS endpoint `/grades` through the existing reverse proxy
   to the service, preserving the path. Limit request bodies to 2 MiB and
   restrict network access to the intended tailnet. Do not expose Postgres
   directly to the phone or the public internet.
5. In the EXISTING NocoDB base, connect the business PostgreSQL source or sync its
   schema if already connected. Show `phone_grades` and `phone_grade_receipts`.
   Use a separate NocoDB database login with only the intended view/edit rights.
   NocoDB's metadata database is not automatically the business data source.
   Official procedure: https://nocodb.com/docs/product/integrations/data-sources/connect-to-data-source
6. In PhoneGrader Settings, set the HTTPS grade-log endpoint ending in `/grades`,
   save the service token in Keychain, then enable manual logging. CLI settings:
   `pgctl config set gradeLogURL https://YOUR-PRIVATE-HOST/grades` and
   `pgctl config set gradeLogEnabled on`. Token entry is in Settings; it is
   deliberately not accepted as a command-line argument.
7. Send a synthetic grade from History, inspect the row in the intended NocoDB
   base, change its summary locally, and send again. There must be one grade row
   with the same UUID and two successful-write receipts. Check rejected tokens,
   unavailable database, and retry after a lost response before using real data.

The app sends the complete private history envelope (including any stored IMEI,
notes, and economics). Photos and Keychain secrets are not part of that envelope.
The server uses one transaction for the upsert and append-only receipt. Retries
keep a single grade row; each successful request adds a receipt. Local UUIDs are
saved BEFORE the HTTP request; successful sync timestamps are saved afterward.
Legacy Airtable metadata is retained only for history-file compatibility and is
never reused as a PostgreSQL UUID. Existing Airtable rows are not bulk-migrated.

Back up both the business PostgreSQL database and the existing NocoDB metadata.
Restoring only NocoDB metadata does not restore an external business database.
