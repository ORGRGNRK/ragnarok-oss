-- Read-only role for the search page. The role itself (LOGIN, NOSUPERUSER/NOCREATEDB/NOCREATEROLE,
-- default_transaction_read_only=on, CONNECTION LIMIT 10) was created once by pipe_admin on Alexus; its
-- password lives only in /opt/script-catalog/web.env (chmod 600). This file records the grants (owner: script_catalog).
GRANT CONNECT ON DATABASE script_catalog TO script_catalog_ro;
GRANT USAGE ON SCHEMA public TO script_catalog_ro;
GRANT SELECT ON scripts, occurrences, script_links, summaries, script_facts, catalog_v TO script_catalog_ro;
-- deliberately NOT granted: change_log
