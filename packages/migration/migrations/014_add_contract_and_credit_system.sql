-- Contract management, credit-based billing, and usage tracking system.
--
-- Introduces:
-- - plan_definition: master table for subscription plan tiers
-- - model_pricing: per-model token pricing for credit calculation (1 credit = $0.0001 USD)
-- - contract: customer subscription linking a plan to credit limits
-- - contract_workspace: junction binding workspaces to a contract
-- - contract_user: customer administrators who can manage workspaces under a contract
-- - token_usage_counter: atomic counter for pre-consume usage enforcement
-- - invoice / invoice_counter: billing document generation support
--
-- Limitations:
-- - franchise_id is a cross-DB reference (no FK constraint to d6e-auth)
-- - period_key uses JST (Asia/Tokyo) for day/week/month boundaries
-- - plan_type on contract is optional; contracts without a plan still work
-- - model_pricing wildcard '*' matches any model for a given provider

-- ============================================================================
-- Plan definition master table
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.plan_definition (
    plan_type TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    max_users INTEGER,
    credit_limit_daily BIGINT,
    credit_limit_weekly BIGINT,
    credit_limit_monthly BIGINT,
    price_monthly INTEGER,
    price_annual INTEGER,
    price_biennial INTEGER,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO frontend.plan_definition
    (plan_type, display_name, max_users, credit_limit_daily, credit_limit_weekly, credit_limit_monthly, price_monthly, price_annual, price_biennial, is_active)
VALUES
    ('basic',      'Basic',      5,    75000,   375000,   1500000,  55000,  605000,  1155000, true),
    ('standard',   'Standard',   15,   200000,  1000000,  4000000,  110000, 1210000, 2310000, true),
    ('premium',    'Premium',    50,   500000,  2500000,  10000000, 220000, 2420000, 4620000, true),
    ('enterprise', 'Enterprise', NULL, NULL,    NULL,     NULL,     NULL,   NULL,    NULL,    true)
ON CONFLICT (plan_type) DO NOTHING;

-- ============================================================================
-- Model pricing for credit calculation
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.model_pricing (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    provider TEXT NOT NULL,
    model_pattern TEXT NOT NULL,
    input_price_per_mtok NUMERIC(10, 4),
    output_price_per_mtok NUMERIC(10, 4),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(provider, model_pattern)
);

INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    -- Anthropic
    ('anthropic', 'claude-opus-4-6',    5.00,  25.00),
    ('anthropic', 'claude-sonnet-4-6',  3.00,  15.00),
    ('anthropic', 'claude-sonnet-4-5',  3.00,  15.00),
    ('anthropic', 'claude-haiku-4-5',   1.00,   5.00),
    -- OpenAI
    ('openai',    'gpt-5.4',            2.50,  15.00),
    ('openai',    'gpt-5.4-mini',      0.75,   4.50),
    ('openai',    'gpt-5.4-nano',      0.10,   0.40),
    -- Google
    ('google',    'gemini-3-flash-preview', 0.15, 0.60),
    ('google',    'gemini-3-pro-preview',  1.25, 10.00),
    -- LM Studio / Ollama (local, free)
    ('lmstudio',  '*',                  0.00,   0.00),
    ('ollama',    '*',                  0.00,   0.00)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();

-- ============================================================================
-- Contract table
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.contract (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    name TEXT NOT NULL,
    franchise_id UUID,
    max_users INTEGER,
    plan_type TEXT REFERENCES frontend.plan_definition(plan_type),
    credit_limit_daily BIGINT,
    credit_limit_weekly BIGINT,
    credit_limit_monthly BIGINT,
    billing_period TEXT,
    price_amount INTEGER,
    starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_frontend_contract_franchise
    ON frontend.contract(franchise_id)
    WHERE franchise_id IS NOT NULL;

-- ============================================================================
-- Contract-Workspace junction table
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.contract_workspace (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    contract_id UUID NOT NULL REFERENCES frontend.contract(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(workspace_id)
);

CREATE INDEX IF NOT EXISTS idx_frontend_contract_workspace_workspace
    ON frontend.contract_workspace(workspace_id);

-- ============================================================================
-- Contract-User table (customer administrators)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.contract_user (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    contract_id UUID NOT NULL REFERENCES frontend.contract(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(contract_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_contract_user_user_id
    ON frontend.contract_user(user_id);

CREATE INDEX IF NOT EXISTS idx_contract_user_contract_id
    ON frontend.contract_user(contract_id);

-- ============================================================================
-- Token usage counter for atomic pre-consume pattern
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.token_usage_counter (
    contract_id UUID NOT NULL REFERENCES frontend.contract(id) ON DELETE CASCADE,
    period_type TEXT NOT NULL,
    period_key TEXT NOT NULL,
    total_tokens BIGINT NOT NULL DEFAULT 0,
    total_credits BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (contract_id, period_type, period_key)
);

-- ============================================================================
-- Link llm_usage to contracts
-- ============================================================================

ALTER TABLE frontend.llm_usage
    ADD COLUMN IF NOT EXISTS contract_id UUID REFERENCES frontend.contract(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_contract
    ON frontend.llm_usage(contract_id);

CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_contract_created
    ON frontend.llm_usage(contract_id, created_at DESC);

-- ============================================================================
-- Invoice table for billing support
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.invoice (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    contract_id UUID NOT NULL REFERENCES frontend.contract(id) ON DELETE CASCADE,
    invoice_number TEXT NOT NULL UNIQUE,
    billing_period_start DATE NOT NULL,
    billing_period_end DATE NOT NULL,
    plan_type TEXT,
    plan_name TEXT NOT NULL,
    subtotal INTEGER NOT NULL,
    tax_rate NUMERIC(5, 2) NOT NULL DEFAULT 10.00,
    tax_amount INTEGER NOT NULL,
    total_amount INTEGER NOT NULL,
    notes TEXT,
    issued_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_frontend_invoice_contract
    ON frontend.invoice(contract_id);

-- ============================================================================
-- Invoice number counter (monthly reset)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.invoice_counter (
    year_month TEXT PRIMARY KEY,
    last_number INTEGER NOT NULL DEFAULT 0
);
