-- Apply to the business database, then expose these tables in the EXISTING NocoDB base.
BEGIN;
CREATE TABLE IF NOT EXISTS phone_grades (
    id uuid PRIMARY KEY,
    local_record_id bigint NOT NULL,
    phone_model text NOT NULL,
    grade text NOT NULL CHECK (grade IN ('A','B','C','D','F')),
    summary text NOT NULL,
    graded_at timestamptz NOT NULL,
    grade_json jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS phone_grade_receipts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    grade_id uuid NOT NULL REFERENCES phone_grades(id),
    actor text NOT NULL DEFAULT 'PhoneGrader',
    written_at timestamptz NOT NULL DEFAULT now()
);
COMMIT;
