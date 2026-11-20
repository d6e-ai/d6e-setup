-- Remove franchise_id from contract table.
--
-- franchise_id was a cross-DB reference to d6e-auth for multi-franchise support,
-- but each instance has exactly one franchise, making the per-contract column unnecessary.
-- The user-count endpoint now counts all contracts without franchise filtering.

DROP INDEX IF EXISTS frontend.idx_frontend_contract_franchise;

ALTER TABLE frontend.contract
    DROP COLUMN IF EXISTS franchise_id;
