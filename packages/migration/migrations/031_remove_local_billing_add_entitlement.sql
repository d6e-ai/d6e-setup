-- Migration: drop local billing tables and add the workspace entitlement cache.
--
-- The `central_workspace_billing` plan removes all instance-side billing
-- bookkeeping in favour of d6e-auth. The Drizzle schema definitions for the
-- corresponding tables were deleted; this migration cleans up the database to
-- match by dropping each former billing table and the related counters.
--
-- The new `frontend.workspace_entitlement` table caches the most-recently
-- observed entitlement snapshot pushed from d6e-auth (and lazily refreshed
-- by the entitlement client). Instance-side LLM call sites consult this
-- table to soft-gate AI features while keeping data view / edit available.
--
-- Greenfield migration: no historical billing data is preserved.

BEGIN;

-- Drop legacy local billing tables. Order matters because of FK references:
-- invoice -> contract, contract_user -> contract, contract_workspace -> contract,
-- token_usage_counter -> contract, llm_usage -> chat_session/contract.
-- llm_usage must be dropped before contract because seed.sql attaches a
-- contract_id FK on llm_usage via ALTER TABLE; plan_definition is referenced
-- by contract, so it must be dropped after contract.
DROP TABLE IF EXISTS frontend.invoice;
DROP TABLE IF EXISTS frontend.invoice_counter;
DROP TABLE IF EXISTS frontend.token_usage_counter;
DROP TABLE IF EXISTS frontend.contract_user;
DROP TABLE IF EXISTS frontend.contract_workspace;
DROP TABLE IF EXISTS frontend.llm_usage;
DROP TABLE IF EXISTS frontend.contract;
DROP TABLE IF EXISTS frontend.plan_definition;
DROP TABLE IF EXISTS frontend.model_pricing;

-- Cached entitlement snapshot for each workspace. The instance keeps this
-- locally so chat / workflow / title call sites can perform the soft-gate
-- decision without round-tripping to d6e-auth on every request. The
-- entitlement client writes here on (a) push from d6e-auth, and (b) lazy
-- refresh when the cache is stale or missing.
CREATE TABLE IF NOT EXISTS frontend.workspace_entitlement (
    workspace_id UUID PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'unknown',
    billing_mode TEXT NOT NULL DEFAULT 'stripe',
    plan_code TEXT,
    period_key TEXT,
    grant_credits INTEGER NOT NULL DEFAULT 0,
    used_credits INTEGER NOT NULL DEFAULT 0,
    remaining_credits INTEGER NOT NULL DEFAULT 0,
    overage_credits INTEGER NOT NULL DEFAULT 0,
    overage_enabled BOOLEAN NOT NULL DEFAULT false,
    spending_cap_credits INTEGER,
    trial_ends_at TIMESTAMPTZ,
    llm_enabled BOOLEAN NOT NULL DEFAULT true,
    payload JSONB,
    upstream_updated_at TIMESTAMPTZ,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMIT;
