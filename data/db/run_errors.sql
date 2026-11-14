-- One table for silent failures that used to vanish: model stderr from the agent
-- runner, and a PhoneGrader history.json that failed to decode. NocoDB reads it
-- (the ui login). Inserts come from the admin login inside the database container.
-- The AI logins cannot add, change, or delete rows. No write_log trigger: a model
-- stderr can be large, and this row is the record. Applied by every ./kit up.
-- Safe to re-run. Schema only.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS public."Run Errors" (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at  timestamptz NOT NULL DEFAULT now(),
    source      text NOT NULL,
    area        text NOT NULL,
    run_id      text,
    who         text,
    exit_code   text,
    backup      text,
    message     text NOT NULL
);
CREATE INDEX IF NOT EXISTS run_errors_created ON public."Run Errors" (created_at DESC);

REVOKE ALL ON public."Run Errors" FROM PUBLIC, :"rw_user", :"ro_user", :"ui_user";
GRANT SELECT ON public."Run Errors" TO :"rw_user", :"ro_user", :"ui_user";

COMMIT;
