-- Items the model put in inputs/outputs that name a CLI flag, env var or file that does not appear in the code.
-- summarize.py v3 removes them from inputs/outputs and keeps them here for review.
ALTER TABLE summaries ADD COLUMN IF NOT EXISTS ungrounded JSONB;
