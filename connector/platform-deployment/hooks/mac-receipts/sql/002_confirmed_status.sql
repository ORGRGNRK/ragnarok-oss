-- A file change that was read back from disk after the tool ran (sha256 for a write, the new text for an edit) is
-- "Confirmed" (Ruleset R-75); everything else stays "Observed". Came over from the retired change hook, 2026-11-02.
-- Idempotent.
alter table mac.receipts drop constraint if exists receipts_status_check;
alter table mac.receipts add constraint receipts_status_check check (status in ('Observed','Confirmed','Failed'));
