-- Migration: replace trialing entitlement status with pending and drop
-- trial_ends_at column.
--
-- The 14-day free trial was removed in d6e-auth's drizzle migration 0008.
-- The instance-side entitlement cache mirrors d6e-auth's state and so the
-- trial-related fields are no longer maintained:
--   * status='trialing' rows are reset to 'unknown' so the next entitlement
--     push from d6e-auth overwrites them with the new pending/active/manual
--     status. The fresh push is guaranteed because d6e-auth's same migration
--     pushes entitlement to every instance after the schema change settles.
--   * trial_ends_at column is dropped. No production code path reads it
--     anymore (entitlement-client + billing-banner switched to status-only
--     gating), so dropping is safe in a single migration.
--
-- Greenfield migration: no historical trial data is preserved beyond the
-- status reset above.

BEGIN;

UPDATE frontend.workspace_entitlement
SET status = 'unknown'
WHERE status = 'trialing';

ALTER TABLE frontend.workspace_entitlement
    DROP COLUMN IF EXISTS trial_ends_at;

COMMIT;
