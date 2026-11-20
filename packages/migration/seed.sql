-- D6E Database Schema
-- This file is used by docker-entrypoint-initdb.d (compose.withdb.yml, e2e/compose.yml) and tests

-- Enable pgvector extension for vector similarity search (optional).
-- The extension is treated as optional so seed.sql can be applied to a vanilla
-- postgres image (e.g. the e2e test DB at packages/frontend/e2e/compose.yml,
-- which uses the bare `postgres:18` image without pgvector).
--
-- IMPORTANT: any object that depends on the `vector` type (currently
-- `file_embedding` / `file_embedding_chunk` and their indexes near the bottom
-- of this file) MUST be guarded by the same `pg_extension` check, otherwise
-- the script aborts with `type "vector" does not exist` on a pgvector-less
-- DB. Production / docker-compose use the `pgvector/pgvector` image so the
-- extension is always present there and the embeddings tables are created
-- as expected.
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pgvector extension not available, skipping';
END $$;

-- Create ENUMs (idempotent)
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'workspace_role') THEN
        CREATE TYPE workspace_role AS ENUM ('admin', 'member');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'stf_runtime') THEN
        CREATE TYPE stf_runtime AS ENUM ('js', 'wasm', 'docker');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'policy_operation') THEN
        CREATE TYPE policy_operation AS ENUM ('select', 'insert', 'update', 'delete');
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'policy_mode') THEN
        CREATE TYPE policy_mode AS ENUM ('allow', 'deny');
    END IF;
END $$;

-- Create tables
CREATE TABLE IF NOT EXISTS "user" (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    email TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    can_create_workspace BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS allowed_email (
    email TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS workspace (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    name TEXT NOT NULL,
    ddl_policy_group_id UUID,
    workflow_editor_policy_group_id UUID,
    policy_editor_policy_group_id UUID,
    mcp_timeout_ms INTEGER NOT NULL DEFAULT 300000,
    custom_prompt TEXT,
    auto_embed_files BOOLEAN NOT NULL DEFAULT FALSE,
    auto_embed_tables BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS workspace_external_reference (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    namespace TEXT NOT NULL CHECK (
        namespace ~ '^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$'
    ),
    external_organization_id UUID NOT NULL,
    created_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workspace_external_reference_identity_unique
        UNIQUE(namespace, external_organization_id)
);

CREATE TABLE IF NOT EXISTS workspace_membership (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    role workspace_role NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Pending workspace invitations for users who have not yet logged in to this
-- d6e instance. On first login, apply_pending_invitations() in the API layer
-- converts matching rows here into workspace_membership entries.
--
-- Notes (mirror of migration 033_add_workspace_invitation.sql):
--   - email is stored lowercased so case-insensitive matching against the
--     JWT-provisioned user.email is trivial at login time.
--   - The (workspace_id, email) uniqueness constraint allows the add_member
--     endpoint to return 409 Conflict for duplicate invites symmetrically
--     with the existing duplicate-membership check.
--   - workspace_id uses ON DELETE CASCADE so removing a workspace also reaps
--     its pending invitations. invited_by uses ON DELETE SET NULL so that
--     pending invitations survive the inviter's account deletion.
CREATE TABLE IF NOT EXISTS workspace_invitation (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role workspace_role NOT NULL DEFAULT 'member',
    invited_by UUID REFERENCES public."user"(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workspace_invitation_workspace_email_unique
        UNIQUE (workspace_id, email)
);

CREATE INDEX IF NOT EXISTS workspace_invitation_email_idx
    ON workspace_invitation (email);

CREATE TABLE IF NOT EXISTS api_key (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    name TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

-- user_data スキーマ (顧客データ用、public から分離)
CREATE SCHEMA IF NOT EXISTS user_data;

-- frontend スキーマ (フロントエンド専用データ用)
-- The schema must be created before any `frontend.*` table reference;
-- `frontend.stf_secret` below (mirror of migration 018) and the chat /
-- workspace tables further down both depend on it. Previously the
-- CREATE SCHEMA statement only appeared after `frontend.stf_secret`,
-- which made `npm run test:e2e` fail on a fresh database with
-- `schema "frontend" does not exist` while the test setup ran seed.sql.
CREATE SCHEMA IF NOT EXISTS frontend;

CREATE TABLE IF NOT EXISTS state_transition_function (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    owner_workspace_id UUID NOT NULL REFERENCES workspace(id),
    name TEXT NOT NULL,
    description TEXT,
    is_public BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS state_transition_function_version (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    stf_id UUID NOT NULL REFERENCES state_transition_function(id),
    version TEXT NOT NULL,
    runtime stf_runtime NOT NULL,
    code BYTEA NOT NULL,
    input_schema JSONB,
    output_schema JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Encrypted per-STF environment variables (Docker runtime secrets).
-- Values are AES-256-GCM ciphertext; the API never returns plaintext.
-- Mirror of migration 018; kept here so fresh `docker compose -f compose.withdb.yml up`
-- containers initialize with the table instead of failing the first STF
-- secret upsert with `relation "frontend.stf_secret" does not exist`.
CREATE TABLE IF NOT EXISTS frontend.stf_secret (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    stf_id UUID NOT NULL REFERENCES state_transition_function(id) ON DELETE CASCADE,
    env_key TEXT NOT NULL CHECK (char_length(env_key) <= 255),
    encrypted_value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(stf_id, env_key)
);

CREATE INDEX IF NOT EXISTS idx_frontend_stf_secret_stf_id
    ON frontend.stf_secret(stf_id);

CREATE TABLE IF NOT EXISTS effect (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    owner_workspace_id UUID NOT NULL REFERENCES workspace(id),
    name TEXT NOT NULL,
    description TEXT,
    is_public BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS effect_version (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    effect_id UUID NOT NULL REFERENCES effect(id),
    version TEXT NOT NULL,
    url TEXT NOT NULL,
    method TEXT NOT NULL,
    input_schema JSONB,
    header_mappings JSONB NOT NULL,
    body_mappings JSONB NOT NULL,
    query_mappings JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


CREATE TABLE IF NOT EXISTS workflow (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    name TEXT NOT NULL,
    description TEXT,
    input_schema JSONB,
    input_steps JSONB NOT NULL DEFAULT '[]',
    stf_steps JSONB NOT NULL,
    effect_steps JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS storage_file (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    filename VARCHAR(255) NOT NULL,
    content_type VARCHAR(255) NOT NULL,
    size BIGINT NOT NULL,
    content BYTEA NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_storage_file_workspace ON storage_file(workspace_id);
CREATE INDEX IF NOT EXISTS idx_storage_file_deleted ON storage_file(deleted_at);
-- Upload-age scan for intent-job input file cleanup (migration 044).
CREATE INDEX IF NOT EXISTS idx_storage_file_upload_age
    ON storage_file((metadata->>'source'), created_at, id);

CREATE TABLE IF NOT EXISTS policy_group (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    name TEXT NOT NULL,
    user_ids UUID[] NOT NULL,
    stf_ids UUID[] NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS policy (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    policy_group_id UUID NOT NULL REFERENCES policy_group(id),
    mode policy_mode NOT NULL,
    operation policy_operation NOT NULL,
    condition JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    api_key_id UUID REFERENCES api_key(id),
    workspace_id UUID REFERENCES workspace(id),
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id UUID,
    details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_workspace_created_at ON audit_log (workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_action ON audit_log (action);
CREATE INDEX IF NOT EXISTS idx_audit_log_resource_type ON audit_log (resource_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_user_id ON audit_log (user_id);

-- STF Libraries (pre-registered JavaScript libraries for STF imports)
CREATE TABLE IF NOT EXISTS stf_library (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    name TEXT NOT NULL UNIQUE,
    version TEXT NOT NULL,
    code BYTEA NOT NULL,
    type_definitions TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stf_library_name ON stf_library(name);

-- Chat sessions for AI agent conversations
CREATE TABLE IF NOT EXISTS frontend.chat_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    -- Creating user; NULL for sessions created before ownership was recorded.
    user_id UUID,
    title TEXT,
    messages JSONB NOT NULL DEFAULT '[]',
    sns_source TEXT,
    external_conversation_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_frontend_chat_session_sns_external
    ON frontend.chat_session (workspace_id, sns_source, external_conversation_key)
    WHERE sns_source IS NOT NULL AND external_conversation_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_workspace_user
    ON frontend.chat_session (workspace_id, user_id);

-- SaaS credential storage (encrypted OAuth tokens and API keys)
CREATE TABLE IF NOT EXISTS frontend.saas_credential (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    provider TEXT NOT NULL,
    auth_type TEXT NOT NULL,
    access_token TEXT,
    refresh_token TEXT,
    token_expires_at TIMESTAMPTZ,
    api_token TEXT,
    provider_config JSONB,
    connected_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(workspace_id, provider)
);

-- MCP server configurations
CREATE TABLE IF NOT EXISTS frontend.mcp_server (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    headers JSONB,
    enabled BOOLEAN NOT NULL DEFAULT true,
    saas_credential_id UUID REFERENCES frontend.saas_credential(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_workspace ON frontend.chat_session(workspace_id);
CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_updated_at ON frontend.chat_session(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_frontend_mcp_server_workspace ON frontend.mcp_server(workspace_id);

-- ============================================================================
-- Workspace Entitlement Cache
-- ============================================================================
-- Cached snapshot of each workspace's entitlement pushed from d6e-auth (and
-- lazily refreshed by the entitlement client). Instance-side LLM call sites
-- consult this table to soft-gate AI features while keeping data view / edit
-- available. All billing bookkeeping (contracts, invoices, token counters,
-- model pricing, llm_usage) lives centrally in d6e-auth now and was removed
-- from the instance in migration 031.
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
    llm_enabled BOOLEAN NOT NULL DEFAULT true,
    payload JSONB,
    upstream_updated_at TIMESTAMPTZ,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The free-trial flow was removed (see d6e-auth migration 0008). Existing
-- entitlement caches that still reference the trialing status are migrated to
-- 'unknown' here so subsequent push/pull cycles overwrite them with the new
-- pending/active/manual taxonomy. The trial_ends_at column is dropped the
-- same way (idempotent) since no caller reads it anymore.
ALTER TABLE frontend.workspace_entitlement
    DROP COLUMN IF EXISTS trial_ends_at;

UPDATE frontend.workspace_entitlement
SET status = 'unknown'
WHERE status = 'trialing';

-- ============================================================================
-- Pinned Charts (Dashboard saved charts)
-- ============================================================================

-- Chart type ENUM
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chart_type') THEN
        CREATE TYPE chart_type AS ENUM ('bar', 'line', 'pie', 'table');
    END IF;
END $$;

-- Pinned Charts table
CREATE TABLE IF NOT EXISTS frontend.pinned_chart (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    
    -- Chart settings
    title TEXT NOT NULL,
    description TEXT,
    sql_query TEXT NOT NULL,  -- SQL query to execute (always fetches latest data)
    chart_type chart_type NOT NULL,
    
    -- Chart axis settings (optional)
    x_axis_column TEXT,  -- Column name for X axis
    y_axis_columns TEXT[],  -- Column names for Y axis (supports multiple)
    
    -- Display settings
    display_order INTEGER NOT NULL DEFAULT 0,  -- Order on dashboard
    is_visible BOOLEAN NOT NULL DEFAULT true,  -- Show/hide toggle
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ  -- Soft delete
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pinned_chart_workspace 
    ON frontend.pinned_chart(workspace_id) 
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_pinned_chart_order 
    ON frontend.pinned_chart(workspace_id, display_order) 
    WHERE deleted_at IS NULL AND is_visible = true;

-- ============================================================================
-- User Settings (Stripe customer ID, etc.)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.user_settings (
    user_id UUID PRIMARY KEY,
    stripe_customer_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_settings_stripe_customer_id 
    ON frontend.user_settings(stripe_customer_id);

-- ============================================================================
-- User Workspace Settings (per-user, per-workspace settings)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.user_workspace_settings (
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    workspace_mode TEXT NOT NULL DEFAULT 'simple',
    hallucination_verification_enabled BOOLEAN NOT NULL DEFAULT false,
    verification_provider TEXT NOT NULL DEFAULT 'anthropic',
    verification_model TEXT NOT NULL DEFAULT 'claude-haiku-5-5',
    mcp_timeout_ms INTEGER NOT NULL DEFAULT 300000,
    sql_approval_mode TEXT NOT NULL DEFAULT 'write_only',
    memory_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    memory_limit INTEGER NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, workspace_id)
);

CREATE INDEX IF NOT EXISTS idx_user_workspace_settings_workspace 
    ON frontend.user_workspace_settings(workspace_id);

-- ============================================================================
-- User Memory (per-user, per-workspace persistent memory from conversations)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.user_memory (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'preference',
    source_session_id UUID,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_memory_content
    ON frontend.user_memory (user_id, workspace_id, content_hash);

CREATE INDEX IF NOT EXISTS ix_user_memory_user_workspace
    ON frontend.user_memory (user_id, workspace_id, updated_at DESC);

-- Table column order - stores per-user, per-workspace, per-table column display order
CREATE TABLE IF NOT EXISTS frontend.table_column_order (
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    column_order JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, workspace_id, table_name)
);

-- ============================================================================
-- Workspace Plugin (marketplace plugin installations per workspace)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_plugin (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    plugin_namespace TEXT NOT NULL,
    plugin_name TEXT NOT NULL,
    installed_version TEXT NOT NULL,
    manifest_url TEXT NOT NULL,
    tier TEXT NOT NULL CHECK (tier IN ('verified', 'unverified')),
    template_prompt TEXT,
    installed_resources JSONB,
    installed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workspace_plugin_workspace_unique
        UNIQUE(workspace_id, plugin_namespace, plugin_name)
);

CREATE INDEX IF NOT EXISTS idx_frontend_workspace_plugin_workspace
    ON frontend.workspace_plugin(workspace_id);

-- Mirror of packages/migration/migrations/054_add_workspace_plugin_activation_fence.sql.
-- Retained across Plugin uninstall so conditional activation revisions never reset.
CREATE TABLE IF NOT EXISTS frontend.workspace_plugin_activation_fence (
    workspace_id UUID NOT NULL,
    plugin_namespace TEXT NOT NULL,
    plugin_name TEXT NOT NULL,
    activation_revision BIGINT NOT NULL,
    requested_version TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (workspace_id, plugin_namespace, plugin_name),
    CONSTRAINT workspace_plugin_activation_fence_revision_check CHECK (
        activation_revision > 0 AND activation_revision <= 9007199254740991
    )
);

-- ============================================================================
-- Workspace Skill (workspace-scoped custom Agent Skills: SKILL.md + files)
-- ============================================================================
-- Mirror of packages/migration/migrations/039_workspace_skill.sql. The chat
-- pipeline loads enabled skills on every request, so a fresh database without
-- these tables fails chat with `relation "frontend.workspace_skill" does not
-- exist`.

CREATE TABLE IF NOT EXISTS frontend.workspace_skill (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    content TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    source TEXT NOT NULL DEFAULT 'manual',
    source_url TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workspace_skill_workspace
    ON frontend.workspace_skill(workspace_id);

CREATE TABLE IF NOT EXISTS frontend.workspace_skill_file (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    skill_id UUID NOT NULL REFERENCES frontend.workspace_skill(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    kind TEXT NOT NULL,
    content TEXT,
    storage_file_id UUID REFERENCES storage_file(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (skill_id, path),
    CONSTRAINT workspace_skill_file_path_no_dotdot CHECK (path NOT LIKE '%..%')
);

CREATE INDEX IF NOT EXISTS idx_workspace_skill_file_skill
    ON frontend.workspace_skill_file(skill_id);

-- ============================================================================
-- Workspace Prompt Rules (individually manageable prompt segments for AI context)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_prompt_rule (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workspace_prompt_rule_workspace_sort
    ON frontend.workspace_prompt_rule(workspace_id, sort_order);

-- ============================================================================
-- Workspace Title Rule (per-workspace naming guideline for chat session titles)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_title_rule (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- Workspace Default Models (admin-managed default models per workspace,
-- for both the chat UI and the SNS bot pipeline)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_default_models (
    workspace_id  UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    chat_provider TEXT NOT NULL DEFAULT 'openai',
    chat_model    TEXT NOT NULL DEFAULT 'gpt-6-luna',
    chat_service_tier TEXT NOT NULL DEFAULT 'standard',
    sns_provider  TEXT NOT NULL DEFAULT 'openai',
    sns_model     TEXT NOT NULL DEFAULT 'gpt-6-luna',
    sns_service_tier TEXT NOT NULL DEFAULT 'standard',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- Workspace d6e AI Gateway credential (write-only project-scoped virtual key)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_d6e_ai_gateway_credential (
    workspace_id          UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    encrypted_virtual_key TEXT NOT NULL,
    key_hint              TEXT NOT NULL,
    verified_at           TIMESTAMPTZ NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- Workspace Chat Template (custom chat frontend shown when dashboard disabled)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_chat_template (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    icon TEXT NOT NULL DEFAULT '',
    icon_gradient TEXT,
    subtitle TEXT,
    title TEXT NOT NULL,
    description TEXT,
    upload_card_title TEXT NOT NULL,
    upload_card_description TEXT,
    upload_button_label TEXT NOT NULL DEFAULT 'Choose file',
    history_section_title TEXT,
    send_instruction TEXT NOT NULL,
    accepted_file_types TEXT[] NOT NULL DEFAULT ARRAY['image/*', 'application/pdf'],
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    -- Custom UI fields added by migration 026.
    -- See packages/migration/migrations/026_extend_workspace_chat_template.sql
    -- for the rationale and per-column documentation. Each field maps 1:1 to
    -- a column the SvelteKit settings page (and the d6e_*_chat_template MCP
    -- tools) can drive, letting non-technical admins switch the workspace
    -- landing experience without code changes.
    greeting_message TEXT,
    brand_name TEXT,
    hero_layout TEXT NOT NULL DEFAULT 'compact'
        CHECK (hero_layout IN ('compact', 'hero')),
    quick_actions JSONB NOT NULL DEFAULT '[]'::jsonb,
    theme_accent TEXT
        CHECK (theme_accent IS NULL OR theme_accent IN
            ('green', 'blue', 'purple', 'orange', 'rose', 'slate')),
    group_history_by_date BOOLEAN NOT NULL DEFAULT FALSE,
    -- Sidebar nav + completed-tasks section heading overrides added by
    -- migration 027. NULL means "use the default i18n string". See
    -- packages/migration/migrations/027_extend_chat_template_labels.sql for
    -- the rationale.
    nav_label_agents TEXT,
    nav_label_tasks TEXT,
    task_ai_answer_label TEXT,
    task_learning_label TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workspace_chat_template_workspace
    ON frontend.workspace_chat_template(workspace_id);

CREATE UNIQUE INDEX IF NOT EXISTS uniq_workspace_chat_template_active
    ON frontend.workspace_chat_template(workspace_id)
    WHERE is_active = TRUE;

-- ============================================================================
-- Workspace Dashboard Setting (admin toggle for showing the dashboard)
-- ============================================================================

CREATE TABLE IF NOT EXISTS frontend.workspace_dashboard_setting (
    workspace_id      UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    dashboard_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Document tables (for doc co-authoring and internal communications)
CREATE TABLE IF NOT EXISTS document (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    title TEXT NOT NULL,
    doc_type TEXT NOT NULL DEFAULT 'general',
    status TEXT NOT NULL DEFAULT 'draft',
    content TEXT NOT NULL DEFAULT '',
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS document_version (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    document_id UUID NOT NULL REFERENCES document(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    content TEXT NOT NULL,
    change_summary TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_document_workspace_updated_at ON document (workspace_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_document_doc_type ON document (doc_type);
CREATE INDEX IF NOT EXISTS idx_document_status ON document (status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_document_version_doc_version ON document_version (document_id, version_number);

-- ============================================================================
-- Embedding Config (tracks vector embedding settings per table/column)
-- ============================================================================

CREATE TABLE IF NOT EXISTS embedding_config (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    table_name TEXT NOT NULL,
    source_column TEXT NOT NULL,
    embedding_column TEXT NOT NULL,
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'completed',
    error_message TEXT,
    job_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, table_name, source_column)
);

CREATE INDEX IF NOT EXISTS idx_embedding_config_workspace_status
    ON embedding_config (workspace_id, status);

-- ============================================================================
-- File Embeddings (multimodal vector search via Gemini Embedding 2)
-- ============================================================================
--
-- These tables depend on the `vector` column type from the pgvector extension.
-- The CREATE EXTENSION call near the top of this file is wrapped in a
-- `EXCEPTION WHEN OTHERS` block so that vanilla postgres images (used by the
-- e2e test DB) keep working without pgvector — but that means any DDL that
-- references the `vector` type must also be guarded, otherwise the whole
-- seed aborts with `type "vector" does not exist` and leaves the schema
-- half-applied (which previously broke `npm run test:e2e`).
--
-- The block below uses `EXECUTE` inside a DO block so the embedding-table
-- DDL is parsed lazily; on a pgvector-less DB the IF branch is never taken
-- and the embedding tables are simply skipped. Production / docker-compose
-- use the `pgvector/pgvector` image, so the extension is always present and
-- this branch creates the tables exactly as before.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        EXECUTE $sql$
            CREATE TABLE IF NOT EXISTS file_embedding (
                id UUID PRIMARY KEY DEFAULT uuidv7(),
                workspace_id UUID NOT NULL REFERENCES workspace(id),
                file_id UUID NOT NULL REFERENCES storage_file(id),
                model TEXT NOT NULL,
                dimensions INTEGER NOT NULL,
                embedding vector,
                status TEXT NOT NULL DEFAULT 'pending',
                error_message TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (workspace_id, file_id)
            )
        $sql$;

        EXECUTE $sql$
            CREATE TABLE IF NOT EXISTS file_embedding_chunk (
                id UUID PRIMARY KEY DEFAULT uuidv7(),
                file_embedding_id UUID NOT NULL REFERENCES file_embedding(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                chunk_type TEXT NOT NULL,
                chunk_label TEXT,
                embedding vector,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (file_embedding_id, chunk_index)
            )
        $sql$;

        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_file_embedding_workspace_status ON file_embedding (workspace_id, status)';
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_file_embedding_file_id ON file_embedding (file_id)';
    ELSE
        RAISE NOTICE 'pgvector extension not available; skipping file_embedding / file_embedding_chunk tables and their indexes';
    END IF;
END $$;

-- Google Drive local mirror sync tables (migration 034).
-- Mirror of packages/migration/migrations/034_add_drive_sync.sql.
CREATE TABLE IF NOT EXISTS frontend.drive_sync_config (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sync_interval_seconds INTEGER NOT NULL DEFAULT 900,
    last_synced_at TIMESTAMPTZ,
    last_sync_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS frontend.drive_sync_root (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    drive_id TEXT NOT NULL,
    drive_type TEXT NOT NULL CHECK (drive_type IN ('folder', 'shared_drive', 'my_drive', 'shared_with_me')),
    name TEXT NOT NULL,
    shared_drive_id TEXT,
    start_page_token TEXT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, drive_id)
);

CREATE INDEX IF NOT EXISTS idx_drive_sync_root_workspace
    ON frontend.drive_sync_root(workspace_id);

CREATE TABLE IF NOT EXISTS frontend.drive_sync_node (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    root_id UUID NOT NULL REFERENCES frontend.drive_sync_root(id) ON DELETE CASCADE,
    drive_id TEXT NOT NULL,
    parent_id UUID REFERENCES frontend.drive_sync_node(id) ON DELETE SET NULL,
    parent_drive_id TEXT,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    is_folder BOOLEAN NOT NULL,
    mime_type TEXT NOT NULL,
    size BIGINT NOT NULL DEFAULT 0,
    drive_modified_time TIMESTAMPTZ,
    md5_checksum TEXT,
    storage_file_id UUID REFERENCES storage_file(id) ON DELETE SET NULL,
    cached_modified_time TIMESTAMPTZ,
    cache_accessed_at TIMESTAMPTZ,
    trashed BOOLEAN NOT NULL DEFAULT FALSE,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, drive_id)
);

CREATE INDEX IF NOT EXISTS idx_drive_sync_node_workspace
    ON frontend.drive_sync_node(workspace_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_root
    ON frontend.drive_sync_node(root_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_parent
    ON frontend.drive_sync_node(parent_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_path
    ON frontend.drive_sync_node(workspace_id, path);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_cache_accessed
    ON frontend.drive_sync_node(cache_accessed_at)
    WHERE storage_file_id IS NOT NULL;

-- Registered one-shot execution metadata (migration 043).
CREATE TABLE IF NOT EXISTS frontend.ephemeral_execution (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    runtime_profile TEXT NOT NULL,
    profile_snapshot JSONB NOT NULL,
    idempotency_key_digest TEXT NOT NULL,
    request_fingerprint TEXT NOT NULL,
    provider_execution_id TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'provisioning' CHECK (
        status IN ('provisioning', 'running', 'succeeded', 'failed', 'cancelled')
    ),
    cancel_requested_at TIMESTAMPTZ,
    exit_code INTEGER,
    failure_code TEXT CHECK (
        failure_code IS NULL OR failure_code IN (
            'launch_rejected', 'launch_unresolved', 'deadline_exceeded', 'runtime_failed'
        )
    ),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ephemeral_execution_workspace_idempotency_unique
        UNIQUE (workspace_id, idempotency_key_digest)
);

CREATE INDEX IF NOT EXISTS idx_ephemeral_execution_workspace_created
    ON frontend.ephemeral_execution(workspace_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ephemeral_execution_workspace_profile_active_unique
    ON frontend.ephemeral_execution(workspace_id, runtime_profile)
    WHERE status IN ('provisioning', 'running');

-- Async execute-by-intent jobs (migration 037).
-- Mirror of packages/migration/migrations/037_add_intent_job.sql. The enum
-- lives in the `frontend` schema, so the existence check is schema-qualified.
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'frontend' AND t.typname = 'intent_job_status'
    ) THEN
        CREATE TYPE frontend.intent_job_status AS ENUM (
            'queued',
            'running',
            'succeeded',
            'failed',
            'cancelled'
        );
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS frontend.intent_job (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    request_payload JSONB NOT NULL,
    status frontend.intent_job_status NOT NULL DEFAULT 'queued',
    heartbeat_at TIMESTAMPTZ,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    tool_trace JSONB NOT NULL DEFAULT '[]'::jsonb,
    result JSONB,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_intent_job_workspace_user
    ON frontend.intent_job(workspace_id, user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_intent_job_running
    ON frontend.intent_job(workspace_id, status) WHERE status = 'running';

-- Input files held by queued/running intent jobs (migration 044).
CREATE TABLE IF NOT EXISTS frontend.intent_job_input_file (
    job_id UUID NOT NULL REFERENCES frontend.intent_job(id) ON DELETE CASCADE,
    storage_file_id UUID NOT NULL REFERENCES storage_file(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (job_id, storage_file_id)
);

CREATE INDEX IF NOT EXISTS idx_intent_job_input_file_storage_file
    ON frontend.intent_job_input_file(storage_file_id);

-- Voice runtime foundation (migration 045).
-- Voice is additive. Ordinary identity, subscriptions and SaaS credentials are unchanged.
-- Retained call/audit data must not disappear when a workspace is removed.
CREATE TABLE IF NOT EXISTS voice_workspace_setting (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL CHECK (char_length(profile_ref) BETWEEN 1 AND 128),
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    max_duration_seconds INTEGER NOT NULL CHECK (max_duration_seconds BETWEEN 1 AND 300),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    consent_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    consent_at TIMESTAMPTZ NOT NULL,
    settings_version BIGINT NOT NULL DEFAULT 1 CHECK (settings_version > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS voice_call (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    request_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    actor_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    request_hash TEXT NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL,
    profile_version TEXT NOT NULL,
    settings_version BIGINT NOT NULL,
    max_duration_seconds INTEGER NOT NULL CHECK (max_duration_seconds BETWEEN 1 AND 300),
    encrypted_destination TEXT,
    encrypted_nonce TEXT,
    auth_snapshot JSONB,
    state TEXT NOT NULL DEFAULT 'preparing' CHECK (state IN (
        'preparing', 'reservation_unknown', 'reserved', 'dispatching',
        'submission_unknown', 'submitted', 'ended', 'canceled', 'failed'
    )),
    business_state TEXT NOT NULL DEFAULT 'incomplete' CHECK (business_state IN (
        'incomplete', 'needs_review', 'succeeded', 'failed'
    )),
    provider_call_sid TEXT,
    provider_terminal BOOLEAN NOT NULL DEFAULT FALSE,
    start_before TIMESTAMPTZ,
    connect_before TIMESTAMPTZ,
    dispatch_attempted BOOLEAN NOT NULL DEFAULT FALSE,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    session_claimed BOOLEAN NOT NULL DEFAULT FALSE,
    session_generation BIGINT NOT NULL DEFAULT 0,
    turn_generation BIGINT NOT NULL DEFAULT 0 CHECK (turn_generation >= 0),
    session_owner UUID,
    lease_expires_at TIMESTAMPTZ,
    runtime_expires_at TIMESTAMPTZ,
    end_requested BOOLEAN NOT NULL DEFAULT FALSE,
    usage_pending BOOLEAN NOT NULL DEFAULT FALSE,
    suppression_pending BOOLEAN NOT NULL DEFAULT FALSE,
    runtime_reason TEXT CHECK (runtime_reason IN (
        'completed', 'recipient_request', 'runtime_failure', 'deadline', 'relay_disconnected'
    )),
    runtime_duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK (runtime_duration_seconds BETWEEN 0 AND 300),
    cleanup_next_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, request_id),
    UNIQUE (id, workspace_id),
    CHECK (NOT provider_terminal OR (provider_call_sid IS NOT NULL AND state IN ('ended', 'canceled', 'failed'))),
    CHECK (NOT session_claimed OR (session_owner IS NOT NULL AND session_generation > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_workspace_active
    ON voice_call(workspace_id)
    WHERE state IN ('preparing', 'reservation_unknown', 'reserved', 'dispatching', 'submission_unknown', 'submitted');
CREATE INDEX IF NOT EXISTS voice_call_workspace_history ON voice_call(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS voice_call_cleanup ON voice_call(cleanup_next_at)
    WHERE end_requested OR usage_pending OR suppression_pending OR dispatch_attempted;

CREATE TABLE IF NOT EXISTS voice_provider_event (
    event_id UUID PRIMARY KEY,
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    state TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT
);
CREATE TABLE IF NOT EXISTS voice_envelope_replay (
    jti UUID PRIMARY KEY,
    purpose TEXT NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS voice_tool_execution (
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    execution_id UUID NOT NULL,
    capability TEXT NOT NULL,
    input_hash TEXT NOT NULL CHECK (input_hash ~ '^[a-f0-9]{64}$'),
    session_generation BIGINT NOT NULL,
    state TEXT NOT NULL DEFAULT 'started' CHECK (state IN ('started', 'completed', 'unknown')),
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (call_id, execution_id),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT
);

-- Voice Gateway conversation (migration 046).
-- Nullable fields preserve previously approved fixed-fallback settings and calls.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS gateway_model TEXT;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS agent_instructions TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS gateway_model TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS agent_instructions TEXT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_workspace_setting'::regclass AND conname='voice_workspace_gateway_config') THEN
        ALTER TABLE voice_workspace_setting ADD CONSTRAINT voice_workspace_gateway_config CHECK (
            (profile_ref <> 'gateway-conversation-v1' AND gateway_model IS NULL AND agent_instructions IS NULL)
            OR (profile_ref = 'gateway-conversation-v1'
                AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
                AND gateway_model !~ '[[:space:][:cntrl:]]'
                AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
                AND position('://' in gateway_model)=0
                AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
                AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        );
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_gateway_config') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_gateway_config CHECK (
            (profile_ref <> 'gateway-conversation-v1' AND gateway_model IS NULL AND agent_instructions IS NULL)
            OR (profile_ref = 'gateway-conversation-v1'
                AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
                AND gateway_model !~ '[[:space:][:cntrl:]]'
                AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
                AND position('://' in gateway_model)=0
                AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
                AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        );
    END IF;
END $$;

CREATE OR REPLACE FUNCTION voice_call_gateway_snapshot_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.gateway_model IS DISTINCT FROM OLD.gateway_model
        OR NEW.agent_instructions IS DISTINCT FROM OLD.agent_instructions THEN
        RAISE EXCEPTION 'Voice call configuration is immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_call_gateway_snapshot_immutable ON voice_call;
CREATE TRIGGER voice_call_gateway_snapshot_immutable BEFORE UPDATE ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_call_gateway_snapshot_immutable();

-- Voice business result (migration 047).
-- Only bounded FDE result metadata and scoped execution UUIDs are retained.
CREATE UNIQUE INDEX IF NOT EXISTS voice_tool_execution_result_scope
    ON voice_tool_execution(call_id, workspace_id, execution_id, session_generation);

CREATE TABLE IF NOT EXISTS voice_business_result (
    call_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    result_id UUID NOT NULL UNIQUE CHECK (result_id <> '00000000-0000-0000-0000-000000000000'),
    state TEXT NOT NULL CHECK (state IN ('succeeded', 'failed', 'needs_review')),
    reason TEXT NOT NULL CHECK (reason IN (
        'verified_tool_applied', 'tool_no_action', 'policy_rejected',
        'recipient_declined', 'tool_uncertain', 'policy_review_required'
    )),
    request_hash TEXT NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
    evidence_count SMALLINT NOT NULL CHECK (evidence_count BETWEEN 0 AND 8),
    actor_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    session_owner UUID NOT NULL CHECK (session_owner <> '00000000-0000-0000-0000-000000000000'),
    session_generation BIGINT NOT NULL CHECK (session_generation > 0),
    turn_generation BIGINT NOT NULL CHECK (turn_generation >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (call_id, workspace_id, result_id, session_generation),
    CHECK (
        (state = 'succeeded' AND reason = 'verified_tool_applied' AND evidence_count > 0)
        OR (state = 'failed' AND (
            (reason = 'tool_no_action' AND evidence_count > 0)
            OR reason IN ('policy_rejected', 'recipient_declined')
        ))
        OR (state = 'needs_review' AND (
            (reason = 'tool_uncertain' AND evidence_count > 0)
            OR reason = 'policy_review_required'
        ))
    )
);
CREATE TABLE IF NOT EXISTS voice_business_result_evidence (
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    result_id UUID NOT NULL,
    session_generation BIGINT NOT NULL,
    ordinal SMALLINT NOT NULL CHECK (ordinal BETWEEN 1 AND 8),
    execution_id UUID NOT NULL CHECK (execution_id <> '00000000-0000-0000-0000-000000000000'),
    PRIMARY KEY (call_id, execution_id),
    UNIQUE (call_id, ordinal),
    FOREIGN KEY (call_id, workspace_id, result_id, session_generation)
        REFERENCES voice_business_result(call_id, workspace_id, result_id, session_generation) ON DELETE RESTRICT,
    FOREIGN KEY (call_id, workspace_id, execution_id, session_generation)
        REFERENCES voice_tool_execution(call_id, workspace_id, execution_id, session_generation) ON DELETE RESTRICT
);

CREATE OR REPLACE FUNCTION voice_business_result_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Voice business results and evidence are immutable';
END $$;
DROP TRIGGER IF EXISTS voice_business_result_immutable ON voice_business_result;
CREATE TRIGGER voice_business_result_immutable BEFORE UPDATE OR DELETE ON voice_business_result
FOR EACH ROW EXECUTE FUNCTION voice_business_result_immutable();
DROP TRIGGER IF EXISTS voice_business_result_evidence_immutable ON voice_business_result_evidence;
CREATE TRIGGER voice_business_result_evidence_immutable BEFORE UPDATE OR DELETE ON voice_business_result_evidence
FOR EACH ROW EXECUTE FUNCTION voice_business_result_immutable();

-- Deferred completeness makes the bounded link set immutable after the transaction commits.
CREATE OR REPLACE FUNCTION voice_business_result_evidence_complete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    result_call UUID := NEW.call_id;
    expected_count SMALLINT;
    actual_count BIGINT;
BEGIN
    SELECT evidence_count INTO expected_count FROM voice_business_result WHERE call_id=result_call;
    SELECT count(*) INTO actual_count FROM voice_business_result_evidence WHERE call_id=result_call;
    IF expected_count IS NULL OR actual_count <> expected_count
        OR EXISTS (SELECT 1 FROM voice_business_result_evidence WHERE call_id=result_call AND ordinal > expected_count) THEN
        RAISE EXCEPTION 'Voice business result evidence must be complete and bounded';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_evidence_complete ON voice_business_result;
CREATE CONSTRAINT TRIGGER voice_business_result_evidence_complete
AFTER INSERT ON voice_business_result DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION voice_business_result_evidence_complete();
DROP TRIGGER IF EXISTS voice_business_result_evidence_complete ON voice_business_result_evidence;
CREATE CONSTRAINT TRIGGER voice_business_result_evidence_complete
AFTER INSERT ON voice_business_result_evidence DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION voice_business_result_evidence_complete();

CREATE OR REPLACE FUNCTION voice_business_result_projection_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    recorded_state TEXT;
BEGIN
    SELECT state INTO recorded_state FROM voice_business_result WHERE call_id=NEW.id AND workspace_id=NEW.workspace_id;
    IF NEW.business_state IS DISTINCT FROM COALESCE(recorded_state, 'incomplete') THEN
        RAISE EXCEPTION 'Voice business state must match its immutable FDE result';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_projection_guard ON voice_call;
CREATE TRIGGER voice_business_result_projection_guard BEFORE INSERT OR UPDATE OF business_state ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_business_result_projection_guard();

CREATE OR REPLACE FUNCTION voice_business_result_project() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE voice_call SET business_state=NEW.state,updated_at=now()
        WHERE id=NEW.call_id AND workspace_id=NEW.workspace_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_project ON voice_business_result;
CREATE TRIGGER voice_business_result_project AFTER INSERT ON voice_business_result
FOR EACH ROW EXECUTE FUNCTION voice_business_result_project();

-- Reconciliation may settle unknown evidence; an already completed receipt cannot be rewritten.
CREATE OR REPLACE FUNCTION voice_business_result_tool_receipt_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM voice_business_result_evidence WHERE call_id=OLD.call_id AND execution_id=OLD.execution_id)
        AND (NEW.capability IS DISTINCT FROM OLD.capability
            OR NEW.input_hash IS DISTINCT FROM OLD.input_hash
            OR (OLD.state = 'completed' AND (
                NEW.state IS DISTINCT FROM OLD.state OR NEW.result IS DISTINCT FROM OLD.result
            ))) THEN
        RAISE EXCEPTION 'Voice business result tool receipts are immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_tool_receipt_guard ON voice_tool_execution;
CREATE TRIGGER voice_business_result_tool_receipt_guard BEFORE UPDATE ON voice_tool_execution
FOR EACH ROW EXECUTE FUNCTION voice_business_result_tool_receipt_guard();

-- Incoming authority belongs to the workspace; approval attribution is audit only.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS inbound_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS inbound_live_approved BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS voice_service_grant (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL CHECK (char_length(profile_ref) BETWEEN 1 AND 128),
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    capabilities JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(capabilities) = 'array'),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    revoked_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    grant_version BIGINT NOT NULL DEFAULT 1 CHECK (grant_version > 0),
    approved_settings_version BIGINT NOT NULL CHECK (approved_settings_version > 0),
    settings_fingerprint TEXT NOT NULL CHECK (settings_fingerprint ~ '^[a-f0-9]{64}$'),
    approved_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, workspace_id),
    CHECK (NOT enabled OR revoked_at IS NULL)
);

ALTER TABLE voice_call ALTER COLUMN actor_user_id DROP NOT NULL;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'outbound';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'outbound_request';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_principal TEXT NOT NULL DEFAULT 'workspace_user';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_grant_id UUID;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_grant_version BIGINT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS grant_capabilities JSONB;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS runtime_before TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_hash TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS adoption_receipt JSONB;
ALTER TABLE voice_business_result ALTER COLUMN actor_user_id DROP NOT NULL;
ALTER TABLE voice_business_result ADD COLUMN IF NOT EXISTS execution_grant_id UUID;
ALTER TABLE voice_business_result ADD COLUMN IF NOT EXISTS execution_grant_version BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_execution_scope') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_execution_scope CHECK (
            (direction='outbound' AND origin='outbound_request' AND execution_principal='workspace_user'
                AND actor_user_id IS NOT NULL AND execution_grant_id IS NULL AND execution_grant_version IS NULL
                AND grant_capabilities IS NULL AND runtime_before IS NULL AND adoption_receipt IS NULL)
            OR (direction='inbound' AND origin='carrier_inbound' AND execution_principal='workspace_service_grant'
                AND actor_user_id IS NULL AND execution_grant_id IS NOT NULL AND execution_grant_version IS NOT NULL AND execution_grant_version > 0
                AND grant_capabilities IS NOT NULL AND jsonb_typeof(grant_capabilities)='array' AND runtime_before IS NOT NULL
                AND start_before IS NULL AND connect_before IS NOT NULL AND runtime_before >= connect_before
                AND NOT dispatch_attempted AND NOT suppression_pending AND encrypted_destination IS NULL
                AND nonce_hash IS NOT NULL AND nonce_hash ~ '^[a-f0-9]{64}$' AND adoption_receipt IS NOT NULL)
        );
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_execution_grant_scope FOREIGN KEY (execution_grant_id,workspace_id)
            REFERENCES voice_service_grant(id,workspace_id) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_business_result'::regclass AND conname='voice_business_result_execution_scope') THEN
        ALTER TABLE voice_business_result ADD CONSTRAINT voice_business_result_execution_scope CHECK (
            (actor_user_id IS NOT NULL AND execution_grant_id IS NULL AND execution_grant_version IS NULL)
            OR (actor_user_id IS NULL AND execution_grant_id IS NOT NULL AND execution_grant_version IS NOT NULL AND execution_grant_version > 0)
        );
        ALTER TABLE voice_business_result ADD CONSTRAINT voice_business_result_execution_grant_scope FOREIGN KEY (execution_grant_id,workspace_id)
            REFERENCES voice_service_grant(id,workspace_id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS voice_call_nonce_once ON voice_call(nonce_hash) WHERE nonce_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_inbound_provider_once
    ON voice_call((auth_snapshot->>'provider_account_sid'),provider_call_sid) WHERE direction='inbound';

-- Parsed, authenticated metadata only; early terminal evidence cannot be revived by adoption.
CREATE TABLE IF NOT EXISTS voice_inbound_event (
    event_id UUID PRIMARY KEY,
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    event JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_inbound_event_call ON voice_inbound_event(call_id,workspace_id);

CREATE OR REPLACE FUNCTION voice_inbound_snapshot_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.direction IS DISTINCT FROM OLD.direction OR NEW.origin IS DISTINCT FROM OLD.origin
        OR NEW.execution_principal IS DISTINCT FROM OLD.execution_principal
        OR NEW.actor_user_id IS DISTINCT FROM OLD.actor_user_id
        OR NEW.execution_grant_id IS DISTINCT FROM OLD.execution_grant_id
        OR NEW.execution_grant_version IS DISTINCT FROM OLD.execution_grant_version
        OR NEW.grant_capabilities IS DISTINCT FROM OLD.grant_capabilities
        OR (OLD.direction='inbound' AND (
            NEW.request_hash IS DISTINCT FROM OLD.request_hash OR NEW.request_id IS DISTINCT FROM OLD.request_id
            OR NEW.workspace_id IS DISTINCT FROM OLD.workspace_id OR NEW.binding_id IS DISTINCT FROM OLD.binding_id
            OR NEW.configuration_version IS DISTINCT FROM OLD.configuration_version
            OR NEW.profile_ref IS DISTINCT FROM OLD.profile_ref OR NEW.profile_version IS DISTINCT FROM OLD.profile_version
            OR NEW.settings_version IS DISTINCT FROM OLD.settings_version OR NEW.max_duration_seconds IS DISTINCT FROM OLD.max_duration_seconds
            OR NEW.start_before IS DISTINCT FROM OLD.start_before OR NEW.connect_before IS DISTINCT FROM OLD.connect_before
            OR NEW.runtime_before IS DISTINCT FROM OLD.runtime_before OR NEW.nonce_hash IS DISTINCT FROM OLD.nonce_hash
            OR NEW.adoption_receipt IS DISTINCT FROM OLD.adoption_receipt OR NEW.provider_call_sid IS DISTINCT FROM OLD.provider_call_sid
        )) THEN
        RAISE EXCEPTION 'Voice execution scope and incoming receipt are immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_inbound_snapshot_immutable ON voice_call;
CREATE TRIGGER voice_inbound_snapshot_immutable BEFORE UPDATE ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_inbound_snapshot_immutable();

-- Voice bring-your-own telephony (migration 049).
-- Bring-your-own telephony. Strictly additive: new tables/columns/indexes and DROP NOT NULL only.
-- Nothing is dropped here; the legacy Auth columns are retired by a later, separate migration.
-- Retained call/audit data must not disappear when a workspace is removed, hence ON DELETE RESTRICT.

-- Carrier credentials: write-only, AES-256-GCM ciphertext (crate::crypto). Never returned by any API.
CREATE TABLE IF NOT EXISTS voice_provider_connection (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    provider TEXT NOT NULL CHECK (provider IN ('twilio')),
    -- NULL only once soft-deleted and no call can still need it (see credentials::delete_connection).
    encrypted_secret TEXT CHECK (char_length(encrypted_secret) BETWEEN 1 AND 8192),
    key_hint TEXT CHECK (char_length(key_hint) <= 64),
    account_ref TEXT CHECK (char_length(account_ref) <= 128),
    caller_id TEXT CHECK (caller_id ~ '^\+[1-9][0-9]{7,14}$'),
    caller_id_status TEXT NOT NULL DEFAULT 'unknown' CHECK (caller_id_status IN ('owned', 'verified', 'unknown')),
    verified_at TIMESTAMPTZ,
    caller_id_checked_at TIMESTAMPTZ,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CHECK (deleted_at IS NOT NULL OR encrypted_secret IS NOT NULL)
);

-- Per-workspace outbound safety policy, enforced by voice::policy::admit_outbound.
CREATE TABLE IF NOT EXISTS voice_calling_policy (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo' CHECK (char_length(timezone) BETWEEN 1 AND 64),
    windows JSONB NOT NULL DEFAULT '[{"weekdays":[1,2,3,4,5,6,7],"start":"08:00","end":"22:00"}]'::jsonb
        CHECK (jsonb_typeof(windows) = 'array' AND jsonb_array_length(windows) BETWEEN 1 AND 8),
    allowed_prefixes TEXT[] NOT NULL DEFAULT '{+81}'
        CHECK (cardinality(allowed_prefixes) BETWEEN 1 AND 32),
    -- The 045 partial unique index voice_call_workspace_active allows one active call per workspace.
    -- Raising this limit needs a later migration that relaxes that index.
    max_concurrent_calls INTEGER NOT NULL DEFAULT 1 CHECK (max_concurrent_calls = 1),
    max_calls_per_day INTEGER NOT NULL DEFAULT 50 CHECK (max_calls_per_day BETWEEN 1 AND 10000),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- DNC and blacklist: only an HMAC of the destination is stored, plus the last 4 digits for display.
CREATE TABLE IF NOT EXISTS voice_suppression (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    kind TEXT NOT NULL CHECK (kind IN ('dnc', 'blacklist')),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    reason TEXT CHECK (char_length(reason) <= 500),
    source TEXT NOT NULL CHECK (source IN ('manual', 'call_opt_out', 'plugin', 'import')),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, kind, destination_hash)
);
CREATE INDEX IF NOT EXISTS voice_suppression_lookup ON voice_suppression(workspace_id, destination_hash);

CREATE TABLE IF NOT EXISTS voice_call_list (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    description TEXT CHECK (char_length(description) <= 1000),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at TIMESTAMPTZ,
    UNIQUE (id, workspace_id)
);
CREATE INDEX IF NOT EXISTS voice_call_list_workspace ON voice_call_list(workspace_id, created_at DESC);

-- The destination is needed to dial, so it is kept encrypted; the hash is for matching and dedupe only.
CREATE TABLE IF NOT EXISTS voice_call_list_entry (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    list_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    encrypted_destination TEXT NOT NULL CHECK (char_length(encrypted_destination) BETWEEN 1 AND 1024),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    display_name TEXT CHECK (char_length(display_name) <= 200),
    lead_context JSONB CHECK (octet_length(lead_context::text) <= 8192),
    status TEXT NOT NULL DEFAULT 'pending'
        -- 'callback': the lead asked to be called back; called by hand, never dialed unattended.
        CHECK (status IN ('pending', 'calling', 'called', 'skipped', 'failed', 'suppressed', 'callback')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_call_id UUID,
    -- 'deadline' when cleanup closed the entry's last call locally after every deadline passed:
    -- the entry is back in pending if that call never connected, failed otherwise. Cleared when
    -- the entry changes again.
    cleanup_reason TEXT CHECK (cleanup_reason IN ('deadline')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (list_id, workspace_id) REFERENCES voice_call_list(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (list_id, destination_hash)
);
CREATE INDEX IF NOT EXISTS voice_call_list_entry_pending ON voice_call_list_entry(list_id, created_at, id)
    WHERE status = 'pending';

-- Append-only record of settings changes. detail never holds secrets or phone numbers.
CREATE TABLE IF NOT EXISTS voice_settings_audit (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    actor_user_id UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user', 'api_key', 'service')),
    action TEXT NOT NULL CHECK (char_length(action) BETWEEN 1 AND 128),
    target_kind TEXT NOT NULL CHECK (char_length(target_kind) BETWEEN 1 AND 64),
    target_id UUID,
    detail JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (octet_length(detail::text) <= 8192),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_settings_audit_workspace ON voice_settings_audit(workspace_id, created_at DESC);

-- Provider-neutral call identity. The legacy Auth binding columns become optional.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider TEXT;
-- A connection referenced by any call is never hard-deleted; delete is a soft delete.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_connection_id UUID
    REFERENCES voice_provider_connection(id) ON DELETE RESTRICT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS connection_version BIGINT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_account_ref TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS destination_hash TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS call_list_entry_id UUID;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_expires_at TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_consumed_at TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS price TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS price_unit TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_status TEXT;
-- Sticky: the carrier reported the call in progress (answered) at least once. Status reports can
-- arrive out of order, so a later 'ringing' never clears it.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_answered BOOLEAN NOT NULL DEFAULT FALSE;
-- When the dispatch intent committed; the daily limit counts calls by this time.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS dispatched_at TIMESTAMPTZ;
ALTER TABLE voice_call ALTER COLUMN binding_id DROP NOT NULL;
ALTER TABLE voice_call ALTER COLUMN configuration_version DROP NOT NULL;
ALTER TABLE voice_workspace_setting ALTER COLUMN binding_id DROP NOT NULL;
ALTER TABLE voice_workspace_setting ALTER COLUMN configuration_version DROP NOT NULL;

-- Carrier call ids are unique per carrier account. The legacy 048 index stays until it is retired.
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_provider_call_once
    ON voice_call(provider, provider_account_ref, provider_call_sid)
    WHERE provider IS NOT NULL AND provider_call_sid IS NOT NULL;

-- Unattended calling from workflows (ADR decision 10). Off unless a workspace admin turns it on
-- here AND the instance sets D6E_VOICE_UNATTENDED_CALLS_ENABLED=true. Calls are placed as the
-- admin who turned it on.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_calling_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_enabled_by UUID
    REFERENCES "user"(id) ON DELETE RESTRICT;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_enabled_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_workspace_setting'::regclass AND conname='voice_workspace_unattended_owner') THEN
        ALTER TABLE voice_workspace_setting ADD CONSTRAINT voice_workspace_unattended_owner CHECK (
            NOT unattended_calling_enabled OR (unattended_enabled_by IS NOT NULL AND unattended_enabled_at IS NOT NULL)
        );
    END IF;
END $$;

-- A manual callback remembers the status it replaced, so releasing it restores that status.
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS status_before_callback TEXT
    CHECK (status_before_callback IN ('pending', 'called', 'skipped', 'failed', 'suppressed'));
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call_list_entry'::regclass AND conname='voice_call_list_entry_callback_restore') THEN
        ALTER TABLE voice_call_list_entry ADD CONSTRAINT voice_call_list_entry_callback_restore CHECK (
            (status = 'callback') = (status_before_callback IS NOT NULL)
        );
    END IF;
END $$;

-- A lead status compared the way the voice-sales plugin compares it (normStatus): NFKC, trimmed,
-- lowercased, runs of spaces, hyphens and underscores folded to one underscore.
CREATE OR REPLACE FUNCTION voice_lead_status(p_status TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(
        regexp_replace(lower(normalize(COALESCE(p_status, ''), NFKC)), '^\s+|\s+$', '', 'g'),
        '[\s_-]+', '_', 'g')
$$;

-- Why an entry may not be dialed unattended, or NULL when it may. These are the dial.mjs rules,
-- kept in the database: the guard trigger below, the dialer's selection query and its check just
-- before each dial all use this one function. Lead statuses rank like the plugin's: a refusal
-- (DNC) over "not interested" (blacklist) over a callback request.
CREATE OR REPLACE FUNCTION voice_unattended_refusal(p_workspace UUID, p_entry UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN e.id IS NULL OR l.id IS NULL THEN 'entry_not_found'
        WHEN l.archived_at IS NOT NULL THEN 'list_archived'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') IN ('do_not_contact', 'opted_out')
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'dnc') THEN 'do_not_call'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') = 'call_not_interested'
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'blacklist') THEN 'blacklisted'
        -- A callback request is called back by hand (the manual callback list), never auto-dialed.
        WHEN e.status = 'callback'
            OR voice_lead_status(e.lead_context #>> '{lead,status}') IN ('call_callback', 'callback', '折り返し希望')
            THEN 'callback'
        WHEN EXISTS (SELECT 1 FROM voice_call c WHERE c.workspace_id = e.workspace_id
                AND c.call_list_entry_id = e.id AND c.state IN ('reservation_unknown', 'submission_unknown'))
            THEN 'unknown_outcome'
        -- Unattended calling never redials: only entries that were never called qualify.
        WHEN e.last_call_id IS NOT NULL OR e.attempts > 0 OR EXISTS (SELECT 1 FROM voice_call c
                WHERE c.workspace_id = e.workspace_id AND c.call_list_entry_id = e.id) THEN 'already_called'
        WHEN e.status <> 'pending' THEN 'not_pending'
        WHEN NULLIF(btrim(e.lead_context #>> '{lead,lead_id}'), '') IS NULL THEN 'no_lead_id'
    END
    FROM (SELECT 1) AS one
    LEFT JOIN voice_call_list_entry e ON e.workspace_id = p_workspace AND e.id = p_entry
    LEFT JOIN voice_call_list l ON l.id = e.list_id AND l.workspace_id = e.workspace_id
$$;

-- Queue of the voice.place_call workflow effect. One row per entry and attempt, so a workflow
-- that runs again does not queue a second dial. The dialer worker uses the row id as the call's
-- request_id, so a retried attempt finds its call instead of dialing again.
CREATE TABLE IF NOT EXISTS voice_place_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    entry_id UUID NOT NULL REFERENCES voice_call_list_entry(id) ON DELETE CASCADE,
    attempt INTEGER NOT NULL CHECK (attempt >= 0),
    state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN (
        -- suppressed: refused for DNC or blacklist (terminal).
        'queued', 'dialing', 'existing', 'submitted', 'submission_unknown', 'failed', 'refused', 'skipped', 'suppressed'
    )),
    reason TEXT CHECK (char_length(reason) BETWEEN 1 AND 64),
    call_id UUID,
    workflow_id UUID,
    enqueued_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    tries INTEGER NOT NULL DEFAULT 0 CHECK (tries >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, entry_id, attempt),
    CHECK (state NOT IN ('refused', 'skipped', 'suppressed') OR reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS voice_place_request_queued ON voice_place_request(next_attempt_at, created_at)
    WHERE state = 'queued';

-- No row can be queued or claimed for an entry the dial.mjs rules exclude.
CREATE OR REPLACE FUNCTION voice_place_request_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    refusal TEXT;
BEGIN
    IF NEW.state IN ('queued', 'dialing') THEN
        refusal := voice_unattended_refusal(NEW.workspace_id, NEW.entry_id);
        IF refusal IS NOT NULL THEN
            RAISE EXCEPTION 'voice_place_request refused: %', refusal USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER voice_place_request_guard
    BEFORE INSERT OR UPDATE OF state ON voice_place_request
    FOR EACH ROW EXECUTE FUNCTION voice_place_request_guard();

-- Per-list auto-dial (ADR decision 10). Off by default; a workspace admin turns it on with a daily
-- cap, audit-logged. The dialer worker then queues the list's eligible pending entries itself,
-- still behind both unattended gates and every voice_unattended_refusal rule.
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_daily_cap INTEGER NOT NULL DEFAULT 0
    CHECK (auto_dial_daily_cap BETWEEN 0 AND 1000);
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_updated_by UUID
    REFERENCES "user"(id) ON DELETE RESTRICT;
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_updated_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call_list'::regclass AND conname='voice_call_list_auto_dial_owner') THEN
        ALTER TABLE voice_call_list ADD CONSTRAINT voice_call_list_auto_dial_owner CHECK (
            NOT auto_dial_enabled
            OR (auto_dial_daily_cap > 0 AND auto_dial_updated_by IS NOT NULL AND auto_dial_updated_at IS NOT NULL)
        );
    END IF;
END $$;
-- Which path queued a request: a workflow's voice.place_call step or the list's auto-dial.
ALTER TABLE voice_place_request ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'workflow'
    CHECK (origin IN ('workflow', 'auto_dial'));

-- Replaces 046's gateway CHECKs (046 itself is never edited) so a workspace-workflow-v1 setting can
-- store its turn workflow id. gateway-conversation-v1 is unchanged; workspace-workflow-v1 needs no
-- gateway_model and a canonical, non-nil UUID in agent_instructions; any other profile stores
-- neither. Guarded: runs only while a constraint still has the 046 definition. DROP/ADD CONSTRAINT
-- take an ACCESS EXCLUSIVE lock that is held until the migration's transaction commits, so the
-- VALIDATE scan below runs under that same lock: NOT VALID + VALIDATE here does not reduce locking
-- (it would only help if VALIDATE ran in a later transaction). Both tables are small, so the scan
-- is short; apply 049 in a quiet window.
DO $$
DECLARE
    target RECORD;
    rule TEXT := $rule$(
        (profile_ref = 'gateway-conversation-v1'
            AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
            AND gateway_model !~ '[[:space:][:cntrl:]]'
            AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
            AND position('://' in gateway_model)=0
            AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
            AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        OR (profile_ref = 'workspace-workflow-v1'
            AND gateway_model IS NULL
            AND agent_instructions IS NOT NULL
            AND agent_instructions ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND agent_instructions <> '00000000-0000-0000-0000-000000000000')
        OR (profile_ref NOT IN ('gateway-conversation-v1', 'workspace-workflow-v1')
            AND gateway_model IS NULL AND agent_instructions IS NULL)
    )$rule$;
BEGIN
    FOR target IN
        SELECT * FROM (VALUES
            ('voice_workspace_setting'::regclass, 'voice_workspace_gateway_config'),
            ('voice_call'::regclass, 'voice_call_gateway_config')
        ) AS t(tbl, name)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = target.tbl AND conname = target.name
              AND pg_get_constraintdef(oid) LIKE '%workspace-workflow-v1%'
              AND convalidated
        ) THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', target.tbl, target.name);
            EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK %s NOT VALID', target.tbl, target.name, rule);
            EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', target.tbl, target.name);
        END IF;
    END LOOP;
END $$;

-- Retire objects that only the d6e-auth control path used (see the 2026-10-20 BYO telephony ADR).
-- OPERATORS: take a full `pg_dump` of the instance database before applying this migration, and
-- check `SELECT count(*) FROM voice_envelope_replay` first. Dropped data cannot be recovered.
-- Apply only after the BYO call path is deployed and verified; it must stay a separate step from 049.
-- Apply with `psql -v ON_ERROR_STOP=1 -f 050_retire_voice_auth_control.sql`.
-- Guard: refuse to run while the auth path can still be in use, i.e. an unexpired relay replay
-- row exists or a call placed through the auth path (provider IS NULL) is not finished.
-- Every change runs inside this single DO block, so a refusal aborts all of it even when the
-- client keeps going after an error (psql without ON_ERROR_STOP): nothing is dropped.
-- Idempotent: once the replay table is gone only the call check remains.
DO $$
DECLARE
    pending BOOLEAN;
BEGIN
    IF to_regclass('public.voice_envelope_replay') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM voice_envelope_replay WHERE expires_at > now())'
            INTO pending;
        IF pending THEN
            RAISE EXCEPTION '050 refused: voice_envelope_replay has unexpired rows; wait until they expire';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM voice_call
        WHERE provider IS NULL AND state NOT IN ('ended', 'canceled', 'failed')
    ) THEN
        RAISE EXCEPTION '050 refused: voice_call has unfinished calls placed through the auth path (provider IS NULL)';
    END IF;
    DROP TABLE IF EXISTS voice_envelope_replay;
    -- Replaced by voice_call_provider_call_once (049), which keys on provider and provider_account_ref.
    DROP INDEX IF EXISTS voice_call_inbound_provider_once;
    -- Auth binding identifiers no longer exist for service grants or carrier inbound events.
    ALTER TABLE voice_service_grant ALTER COLUMN binding_id DROP NOT NULL;
    ALTER TABLE voice_service_grant ALTER COLUMN configuration_version DROP NOT NULL;
    ALTER TABLE voice_inbound_event ALTER COLUMN binding_id DROP NOT NULL;
END $$;

-- Voice inbound reception (migration 051).
-- Voice inbound reception v1: reception and callback handling only (no voicemail, no transfer).
-- Additive: new tables and nullable or defaulted columns, plus one widened CHECK. It does not
-- depend on 050 and can be applied before or after it. Phone numbers are stored only as an
-- AES-GCM ciphertext (workspace-bound), an HMAC and the last four digits; never in plain text.

-- One row per workspace; absent means the defaults below.
CREATE TABLE IF NOT EXISTS voice_inbound_policy (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo' CHECK (char_length(timezone) BETWEEN 1 AND 64),
    windows JSONB NOT NULL DEFAULT '[{"weekdays":[1,2,3,4,5],"start":"09:00","end":"18:00"}]'::jsonb
        CHECK (jsonb_typeof(windows) = 'array' AND jsonb_array_length(windows) BETWEEN 1 AND 8),
    -- Spoken by d6e outside the windows (say, then hang up); no turn workflow runs.
    after_hours_message TEXT NOT NULL
        DEFAULT 'お電話ありがとうございます。本日の受付は終了しました。恐れ入りますが、受付時間内に改めておかけ直しください。'
        CHECK (char_length(after_hours_message) <= 200 AND length(btrim(after_hours_message)) > 0
            AND after_hours_message !~ '[[:cntrl:]]'),
    max_duration_seconds INTEGER NOT NULL DEFAULT 300 CHECK (max_duration_seconds BETWEEN 30 AND 300),
    -- Answered calls (connected or after-hours message) per policy-timezone day.
    max_calls_per_day INTEGER NOT NULL DEFAULT 50 CHECK (max_calls_per_day BETWEEN 1 AND 10000),
    -- Answered calls per caller number in any rolling hour.
    per_caller_per_hour INTEGER NOT NULL DEFAULT 3 CHECK (per_caller_per_hour BETWEEN 1 AND 60),
    allow_anonymous BOOLEAN NOT NULL DEFAULT FALSE,
    -- Match callers against the workspace's call lists (caller_match, callback updates).
    -- Off by default: a reservation workspace must never match sales leads.
    match_call_lists BOOLEAN NOT NULL DEFAULT FALSE,
    -- A caller who asks not to be called joins the workspace DNC list (C4). On by default, so
    -- no later outbound call reaches them; a workspace that only receives calls may turn it off.
    opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT TRUE,
    -- Summaries, caller ciphertexts/hashes and attempt rows older than this are purged.
    retention_days INTEGER NOT NULL DEFAULT 90 CHECK (retention_days BETWEEN 1 AND 365),
    -- Optional inbound-only turn workflow (workspace-workflow-v1); NULL uses the shared one.
    inbound_workflow_id UUID CHECK (inbound_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Columns added after the first 051 revision: a database that already ran it gets them here.
ALTER TABLE voice_inbound_policy ADD COLUMN IF NOT EXISTS match_call_lists BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_inbound_policy ADD COLUMN IF NOT EXISTS opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT TRUE;

-- Inbound block list. Separate from voice_suppression: it refuses incoming calls only and never
-- changes outbound DNC or blacklist decisions.
CREATE TABLE IF NOT EXISTS voice_inbound_block (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    caller_hash TEXT NOT NULL CHECK (caller_hash ~ '^[a-f0-9]{64}$'),
    caller_hint TEXT NOT NULL CHECK (caller_hint ~ '^[0-9]{1,4}$'),
    reason TEXT CHECK (char_length(reason) <= 500),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, caller_hash)
);

-- Every decision on an authenticated offer for a workspace that accepts calls, for the rate
-- limit, the daily cap and the admin view. No number, only its HMAC (NULL when anonymous).
CREATE TABLE IF NOT EXISTS voice_inbound_attempt (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    caller_hash TEXT CHECK (caller_hash ~ '^[a-f0-9]{64}$'),
    outcome TEXT NOT NULL CHECK (outcome IN ('connected', 'after_hours', 'rejected', 'busy')),
    reason TEXT CHECK (reason IN ('anonymous', 'blocked', 'caller_rate', 'daily_cap')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((outcome = 'rejected') = (reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS voice_inbound_attempt_workspace ON voice_inbound_attempt(workspace_id, created_at);
CREATE INDEX IF NOT EXISTS voice_inbound_attempt_caller ON voice_inbound_attempt(workspace_id, caller_hash, created_at)
    WHERE caller_hash IS NOT NULL;

-- The inbound caller. Outbound rows never carry these.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS encrypted_caller TEXT
    CHECK (char_length(encrypted_caller) BETWEEN 1 AND 1024);
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_hash TEXT CHECK (caller_hash ~ '^[a-f0-9]{64}$');
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_hint TEXT CHECK (caller_hint ~ '^[0-9]{1,4}$');
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_anonymous BOOLEAN NOT NULL DEFAULT FALSE;
-- The call-list entry the caller's number matched (a hint, not identity).
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS matched_entry_id UUID;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_inbound_caller') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_inbound_caller CHECK (
            (encrypted_caller IS NULL) = (caller_hash IS NULL)
            AND (caller_hash IS NULL) = (caller_hint IS NULL)
            AND (direction = 'inbound' OR (caller_hash IS NULL AND NOT caller_anonymous AND matched_entry_id IS NULL))
            AND NOT (caller_anonymous AND caller_hash IS NOT NULL)
        );
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS voice_call_inbound_caller ON voice_call(workspace_id, caller_hash, created_at)
    WHERE direction = 'inbound' AND caller_hash IS NOT NULL;

-- The final action's call summary (contract C2). Admin-only; purged after retention_days.
CREATE TABLE IF NOT EXISTS voice_inbound_summary (
    call_id UUID PRIMARY KEY REFERENCES voice_call(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    next_action TEXT NOT NULL
        CHECK (next_action IN ('none', 'callback', 'email', 'meeting', 'human_review', 'block')),
    outcome TEXT NOT NULL CHECK (outcome IN ('inquiry', 'callback_requested', 'meeting_requested',
        'email_ok', 'callback_done', 'not_interested', 'declined', 'spam', 'review')),
    summary TEXT CHECK (char_length(summary) <= 1000),
    preferred_time TEXT CHECK (char_length(preferred_time) <= 200),
    email TEXT CHECK (char_length(email) <= 200),
    contact_name TEXT CHECK (char_length(contact_name) <= 200),
    company TEXT CHECK (char_length(company) <= 200),
    -- Kept only when it is the lead d6e matched for this call.
    matched_lead_id TEXT CHECK (char_length(matched_lead_id) BETWEEN 1 AND 200),
    callback_resolved BOOLEAN NOT NULL DEFAULT FALSE,
    -- What d6e did to the call lists (contract C3).
    list_update TEXT NOT NULL DEFAULT 'none' CHECK (list_update IN ('none', 'callback_done', 'callback_kept')),
    entries_updated INTEGER NOT NULL DEFAULT 0 CHECK (entries_updated >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_inbound_summary_workspace ON voice_inbound_summary(workspace_id, created_at DESC);

-- 'callback_done': a callback the lead's own call resolved. Terminal: it never returns to
-- pending, so it is never auto-dialed (voice_unattended_refusal refuses every non-pending entry).
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS callback_preferred_time TEXT
    CHECK (char_length(callback_preferred_time) <= 200);
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS callback_resolved_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS voice_call_list_entry_caller ON voice_call_list_entry(workspace_id, destination_hash);
-- Widens 049's inline status CHECK (049 itself is not edited). Guarded: runs only while the
-- constraint lacks 'callback_done'. Added NOT VALID, then validated.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'voice_call_list_entry'::regclass AND conname = 'voice_call_list_entry_status_check'
          AND pg_get_constraintdef(oid) LIKE '%callback_done%' AND convalidated
    ) THEN
        ALTER TABLE voice_call_list_entry DROP CONSTRAINT IF EXISTS voice_call_list_entry_status_check;
        ALTER TABLE voice_call_list_entry ADD CONSTRAINT voice_call_list_entry_status_check CHECK (
            status IN ('pending', 'calling', 'called', 'skipped', 'failed', 'suppressed', 'callback', 'callback_done')
        ) NOT VALID;
        ALTER TABLE voice_call_list_entry VALIDATE CONSTRAINT voice_call_list_entry_status_check;
    END IF;
END $$;

-- Allow Telnyx as a second voice carrier next to Twilio.
-- Idempotent: the constraint is dropped by name if present, then recreated with both carriers.
-- Existing rows all hold 'twilio', so re-adding the CHECK validates without data changes.
ALTER TABLE voice_provider_connection DROP CONSTRAINT IF EXISTS voice_provider_connection_provider_check;
ALTER TABLE voice_provider_connection
    ADD CONSTRAINT voice_provider_connection_provider_check CHECK (provider IN ('twilio', 'telnyx'));

-- Registered application execution delegation (migration 055).
-- Purpose-limited application execution acceptance. No request bodies or credentials.
CREATE TABLE IF NOT EXISTS frontend.application_operation_nonce (
    application_id TEXT NOT NULL,
    instance_id UUID NOT NULL,
    request_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (application_id, instance_id, request_id)
);

CREATE INDEX IF NOT EXISTS application_operation_nonce_expiry_idx
    ON frontend.application_operation_nonce (expires_at);

CREATE TABLE IF NOT EXISTS frontend.application_execution_mutation (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    application_id TEXT NOT NULL,
    instance_id UUID NOT NULL,
    external_issuer TEXT NOT NULL,
    external_tenant_id UUID NOT NULL,
    external_actor_id UUID NOT NULL,
    service_actor_id UUID NOT NULL REFERENCES public."user"(id),
    workspace_id UUID NOT NULL REFERENCES public.workspace(id),
    operation TEXT NOT NULL CHECK (operation IN ('execution.launch', 'execution.cancel')),
    registration_revision TEXT NOT NULL,
    runtime_profile TEXT NOT NULL,
    idempotency_key_digest TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    execution_id UUID REFERENCES frontend.ephemeral_execution(id),
    attempt_id UUID,
    attempt_expires_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT application_execution_mutation_identity_unique
        UNIQUE (application_id, instance_id, external_tenant_id, external_actor_id, idempotency_key_digest),
    CONSTRAINT application_execution_mutation_attempt_consistent
        CHECK ((attempt_id IS NULL) = (attempt_expires_at IS NULL))
);

CREATE INDEX IF NOT EXISTS application_execution_mutation_execution_idx
    ON frontend.application_execution_mutation (execution_id)
    WHERE operation = 'execution.launch';

-- Mirror of packages/migration/migrations/056_add_voice_live_foundation.sql.
-- GPT-Live voice foundation (OpenAI Direct SIP + sideband). Strictly additive: new tables and indexes only.
-- d6e talks only to OpenAI in the new path; these tables hold the OpenAI connection and a webhook/sideband
-- event ledger. Retained audit data must not disappear with a workspace, hence ON DELETE RESTRICT.

-- One active OpenAI Live connection per workspace. Secrets are AES-256-GCM ciphertext (crate::crypto via
-- voice::privacy::VoiceKeys) and are never returned by any API. A soft-deleted row keeps its id so the
-- event ledger below can still reference it, but its secrets are wiped (NULL once deleted_at is set).
CREATE TABLE IF NOT EXISTS voice_live_connection (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    openai_project_id TEXT NOT NULL CHECK (openai_project_id LIKE 'proj\_%' AND char_length(openai_project_id) <= 128),
    -- 'instance': use the D6E_VOICE_OPENAI_* values of the deployment. 'workspace': use the secrets below.
    key_source TEXT NOT NULL CHECK (key_source IN ('instance', 'workspace')),
    encrypted_api_key TEXT CHECK (char_length(encrypted_api_key) BETWEEN 1 AND 8192),
    api_key_hint TEXT CHECK (char_length(api_key_hint) <= 64),
    encrypted_webhook_secret TEXT CHECK (char_length(encrypted_webhook_secret) BETWEEN 1 AND 8192),
    sip_provider_url TEXT NOT NULL CHECK (sip_provider_url LIKE 'sips:%' AND char_length(sip_provider_url) <= 255),
    encrypted_trunk_username TEXT CHECK (char_length(encrypted_trunk_username) BETWEEN 1 AND 8192),
    encrypted_trunk_password TEXT CHECK (char_length(encrypted_trunk_password) BETWEEN 1 AND 8192),
    caller_number TEXT NOT NULL CHECK (caller_number ~ '^\+[1-9][0-9]{7,14}$'),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    -- While the connection is live, workspace-held secrets are required exactly when the workspace is
    -- the key source, and the trunk credentials are always required.
    CHECK (
        deleted_at IS NOT NULL
        OR (
            encrypted_trunk_username IS NOT NULL
            AND encrypted_trunk_password IS NOT NULL
            AND (
                (key_source = 'workspace' AND encrypted_api_key IS NOT NULL AND encrypted_webhook_secret IS NOT NULL)
                OR (key_source = 'instance' AND encrypted_api_key IS NULL AND encrypted_webhook_secret IS NULL)
            )
        )
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_connection_workspace_active
    ON voice_live_connection(workspace_id) WHERE deleted_at IS NULL;

-- Dedup ledger for OpenAI webhook deliveries and sideband events. Only the event type, session id and a
-- payload hash are kept: never raw SIP headers, phone numbers or bodies.
CREATE TABLE IF NOT EXISTS voice_live_event (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    source TEXT NOT NULL CHECK (source IN ('webhook', 'sideband')),
    event_id TEXT NOT NULL CHECK (char_length(event_id) BETWEEN 1 AND 256),
    event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 128),
    session_id TEXT CHECK (char_length(session_id) <= 256),
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload_hash TEXT NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
    UNIQUE (connection_id, source, event_id)
);
CREATE INDEX IF NOT EXISTS voice_live_event_workspace ON voice_live_event(workspace_id, received_at DESC);

-- Mirror of packages/migration/migrations/057_add_voice_live_session.sql.
-- GPT-Live sideband sessions. Strictly additive: new tables and indexes only.
-- One row per OpenAI Live session that d6e attaches a sideband WebSocket to, plus its transcript.
-- Retained audit data must not disappear with a workspace, hence ON DELETE RESTRICT (as in 056).

-- A live session and the lease that makes exactly one API replica own its sideband attach.
-- Timeline of status: created -> ringing -> answered -> closed; failed (transport.failed) and
-- lost (sideband could not be re-attached, final usage unconfirmed) are terminal as well.
CREATE TABLE IF NOT EXISTS voice_live_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    voice_call_id UUID,
    openai_session_id TEXT NOT NULL UNIQUE CHECK (char_length(openai_session_id) BETWEEN 1 AND 256),
    direction TEXT NOT NULL CHECK (direction IN ('outbound', 'inbound')),
    status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'ringing', 'answered', 'failed', 'closed', 'lost')),
    lease_owner TEXT CHECK (char_length(lease_owner) <= 128),
    lease_expires_at TIMESTAMPTZ,
    attach_attempts INTEGER NOT NULL DEFAULT 0 CHECK (attach_attempts >= 0),
    last_event_at TIMESTAMPTZ,
    close_reason TEXT CHECK (char_length(close_reason) <= 128),
    -- Cumulative voice seconds from session.usage.updated; the final value from session.closed.
    usage_seconds NUMERIC CHECK (usage_seconds >= 0),
    failure_code TEXT CHECK (char_length(failure_code) <= 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    UNIQUE (id, workspace_id),
    FOREIGN KEY (voice_call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT,
    CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL)),
    -- A terminal session holds no lease and has a close time.
    CHECK (status IN ('created', 'ringing', 'answered') OR (lease_owner IS NULL AND closed_at IS NOT NULL))
);
-- The worker query: non-terminal sessions whose lease is free or expired.
CREATE INDEX IF NOT EXISTS voice_live_session_worker ON voice_live_session(lease_expires_at)
    WHERE status IN ('created', 'ringing', 'answered');
CREATE INDEX IF NOT EXISTS voice_live_session_workspace ON voice_live_session(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS voice_live_session_call ON voice_live_session(voice_call_id)
    WHERE voice_call_id IS NOT NULL;

-- Conversation text of a live session. The text is AES-256-GCM ciphertext (VoiceKeys::seal_live_secret,
-- bound to the workspace and session), never plaintext, and is purged after the same retention as
-- inbound call data (voice::live::worker::purge_expired_transcripts, run by the voice cleanup task).
CREATE TABLE IF NOT EXISTS voice_live_transcript_segment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    speaker TEXT NOT NULL CHECK (speaker IN ('caller', 'assistant')),
    start_ms BIGINT NOT NULL CHECK (start_ms >= 0),
    end_ms BIGINT NOT NULL CHECK (end_ms >= start_ms),
    encrypted_text TEXT NOT NULL CHECK (char_length(encrypted_text) BETWEEN 1 AND 262144),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS voice_live_transcript_segment_session
    ON voice_live_transcript_segment(live_session_id, start_ms);
CREATE INDEX IF NOT EXISTS voice_live_transcript_segment_created
    ON voice_live_transcript_segment(created_at);

-- Mirror of packages/migration/migrations/058_add_voice_live_delegation.sql.
-- GPT-Live client delegation: agent settings, CRM binding, delegation log and tool ledger.
-- Strictly additive: new tables and indexes only. Retained audit data must not disappear with a
-- workspace, hence ON DELETE RESTRICT (as in 056/057).
-- Workflow ids are plain UUIDs without a foreign key, like voice_inbound_policy.inbound_workflow_id (051):
-- the admin API checks the workflow when the setting is saved and the runner checks it again when it runs.

-- One active agent setting per workspace (PR-4 adds caller name, AI disclosure and opt-out handling).
-- fast_model answers a delegation within a short deadline; slow_model is handed to the delegate workflow.
-- Model ids follow gateway_client::valid_model_id: no whitespace, control characters or URLs.
CREATE TABLE IF NOT EXISTS voice_agent_setting (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    fast_model TEXT NOT NULL CHECK (
        char_length(fast_model) BETWEEN 1 AND 256 AND fast_model !~ '[[:space:][:cntrl:]]' AND fast_model !~ '://'
    ),
    slow_model TEXT CHECK (
        char_length(slow_model) BETWEEN 1 AND 256 AND slow_model !~ '[[:space:][:cntrl:]]' AND slow_model !~ '://'
    ),
    context_workflow_id UUID CHECK (context_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    delegate_workflow_id UUID CHECK (delegate_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    post_call_workflow_id UUID CHECK (post_call_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_agent_setting_workspace_active
    ON voice_agent_setting(workspace_id) WHERE deleted_at IS NULL;

-- Where the CRM tools may read and write. The table and every column come from this row only (never from
-- model output); values are always bound parameters. One active binding per workspace. The identifier
-- checks here are repeated in Rust (voice::live::crm) before any SQL is built.
CREATE TABLE IF NOT EXISTS voice_crm_binding (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 128 AND name !~ '[[:cntrl:]]'),
    -- A workspace-SQL table (not a physical table name): rewritten into the workspace namespace on execution.
    target_table TEXT NOT NULL CHECK (target_table ~ '^[a-z_][a-z0-9_]{0,62}$'),
    key_column TEXT NOT NULL CHECK (key_column ~ '^[a-z_][a-z0-9_]{0,62}$'),
    phone_column TEXT CHECK (phone_column ~ '^[a-z_][a-z0-9_]{0,62}$'),
    -- Logical field -> column: only status, notes, next_action and callback_at, each a plain identifier.
    column_map JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(column_map) = 'object'
        AND NOT jsonb_path_exists(column_map, '$.keyvalue() ? (@.key != "status" && @.key != "notes" && @.key != "next_action" && @.key != "callback_at")')
        AND NOT jsonb_path_exists(column_map, '$.* ? (@.type() != "string")')
        AND NOT jsonb_path_exists(column_map, '$.* ? (!(@ like_regex "^[a-z_][a-z0-9_]{0,62}$"))')
    ),
    allowed_ops TEXT[] NOT NULL CHECK (
        cardinality(allowed_ops) BETWEEN 1 AND 4
        AND allowed_ops <@ ARRAY['lookup', 'update_status', 'log_activity', 'schedule_callback']::text[]
    ),
    -- update_status may only write one of these.
    allowed_statuses TEXT[] NOT NULL DEFAULT '{}'::text[] CHECK (
        cardinality(allowed_statuses) <= 32 AND array_to_string(allowed_statuses, '') !~ '[[:cntrl:]]'
    ),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    -- An allowed write needs its column (and, for update_status, at least one allowed status).
    CHECK (NOT ('update_status' = ANY(allowed_ops)) OR (column_map ->> 'status' IS NOT NULL AND cardinality(allowed_statuses) >= 1)),
    CHECK (NOT ('log_activity' = ANY(allowed_ops)) OR column_map ->> 'notes' IS NOT NULL),
    CHECK (NOT ('schedule_callback' = ANY(allowed_ops)) OR column_map ->> 'callback_at' IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_crm_binding_workspace_active
    ON voice_crm_binding(workspace_id) WHERE deleted_at IS NULL;

-- One row per delegation of a live session. Inserted when the delegation is claimed (which makes a replayed
-- session.delegation.created a no-op) and completed when the answer was appended.
CREATE TABLE IF NOT EXISTS voice_delegation (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL CHECK (char_length(delegation_id) BETWEEN 1 AND 256),
    route TEXT NOT NULL DEFAULT 'fast' CHECK (route IN ('fast', 'slow', 'supervisor')),
    model TEXT CHECK (char_length(model) <= 256),
    latency_ms INTEGER CHECK (latency_ms >= 0),
    result_kind TEXT NOT NULL DEFAULT 'none' CHECK (result_kind IN ('commentary', 'thinking', 'none', 'needs_review', 'error')),
    error_code TEXT CHECK (char_length(error_code) <= 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id)
);
CREATE INDEX IF NOT EXISTS voice_delegation_workspace ON voice_delegation(workspace_id, created_at DESC);

-- Tool ledger of live sessions (voice_tool_execution is bound to the call/turn/session_generation model, which
-- live sessions do not have). The idempotency key is delegation_id + tool. 'started' is written before the
-- tool runs, so a crash mid-write is never repeated blindly (it stays 'started'/'unknown' for a human).
-- A needs_review row is a request for a human decision: the tool is never executed for it. It holds
-- references and hashes only, never CRM data.
CREATE TABLE IF NOT EXISTS voice_live_tool_execution (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL CHECK (char_length(delegation_id) BETWEEN 1 AND 256),
    tool TEXT NOT NULL CHECK (tool IN (
        'crm.lookup', 'crm.update_status', 'crm.log_activity', 'crm.schedule_callback', 'supervisor.review'
    )),
    -- Why a supervisor.review row exists.
    review_reason TEXT CHECK (review_reason IN ('dnc', 'opt_out', 'not_allowed', 'sensitive')),
    input_hash TEXT NOT NULL CHECK (input_hash ~ '^[a-f0-9]{64}$'),
    state TEXT NOT NULL DEFAULT 'started' CHECK (state IN ('started', 'completed', 'unknown')),
    outcome TEXT CHECK (outcome IN ('applied', 'no_action', 'needs_review')),
    result_reference UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id, tool),
    CHECK ((state = 'completed') = (outcome IS NOT NULL)),
    CHECK ((tool = 'supervisor.review') = (review_reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS voice_live_tool_execution_review
    ON voice_live_tool_execution(workspace_id, created_at DESC) WHERE outcome = 'needs_review';

-- Mirror of packages/migration/migrations/059_add_voice_live_compliance.sql.
-- GPT-Live compliance: persona and opt-out settings, human-approved outbound requests and the review queue.
-- Strictly additive: new columns with defaults, new tables and indexes only. Retained audit data must not
-- disappear with a workspace, hence ON DELETE RESTRICT (as in 056-058).

-- Persona and compliance configuration of a workspace. caller_name, voice and opening override the plugin's
-- Const defaults when set; NULL means "use the plugin default". disclose_ai and opt_out_adds_dnc are plain
-- switches that default to OFF. The voice id follows the SessionConfig rule (letters, digits, '_' and '-').
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS caller_name TEXT
    CHECK (char_length(caller_name) BETWEEN 1 AND 64 AND caller_name !~ '[[:cntrl:]]');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS disclose_ai BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS voice TEXT
    CHECK (voice ~ '^[A-Za-z0-9_-]{1,64}$');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS opening TEXT
    CHECK (char_length(opening) BETWEEN 1 AND 1000);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT FALSE;

-- A human-approved outbound call on the GPT-Live path. There is no unattended dialing here: a call is
-- placed only from a row whose approver is recorded (the CHECK below), and the row is the idempotency
-- anchor, so the OpenAI create request (which places a real call and is never retried) is sent at most once.
-- The destination is sealed like the numbers of call list entries (VoiceKeys::seal_destination) and kept
-- with its HMAC and last four digits, so the opt-out and review paths can find the number later.
-- caller_name and disclose_ai are the persona that was in force when the call was placed.
CREATE TABLE IF NOT EXISTS voice_live_call_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    call_list_entry_id UUID REFERENCES voice_call_list_entry(id) ON DELETE SET NULL,
    encrypted_destination TEXT NOT NULL CHECK (char_length(encrypted_destination) BETWEEN 1 AND 1024),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    -- Which path asked for the call. Only 'admin' and 'workflow' requests can be approved; 'auto_dial' is
    -- recorded as refused so the attempt stays visible.
    origin TEXT NOT NULL DEFAULT 'admin' CHECK (origin IN ('admin', 'workflow', 'auto_dial')),
    requested_by UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ,
    state TEXT NOT NULL DEFAULT 'pending_approval' CHECK (state IN (
        'pending_approval', 'approved', 'refused', 'dispatching', 'dispatched', 'ambiguous', 'failed', 'cancelled'
    )),
    -- Why a request is refused or failed, or what made it ambiguous. A machine-readable code only.
    refusal_code TEXT CHECK (char_length(refusal_code) BETWEEN 1 AND 64),
    live_session_id UUID,
    idempotency_key TEXT NOT NULL CHECK (char_length(idempotency_key) BETWEEN 8 AND 128),
    caller_name TEXT CHECK (char_length(caller_name) BETWEEN 1 AND 64),
    disclose_ai BOOLEAN NOT NULL DEFAULT FALSE,
    dispatch_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, idempotency_key),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    -- No call may be started, or be in an unknown state, without a recorded human approver.
    CHECK (state NOT IN ('dispatching', 'dispatched', 'ambiguous') OR approved_by IS NOT NULL),
    CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
    CHECK (state NOT IN ('refused', 'failed') OR refusal_code IS NOT NULL),
    CHECK (state <> 'dispatched' OR live_session_id IS NOT NULL),
    CHECK (state NOT IN ('dispatching', 'dispatched', 'ambiguous') OR dispatch_started_at IS NOT NULL),
    CHECK (origin <> 'auto_dial' OR state = 'refused')
);
-- One request per number may be waiting or starting at a time (the pre-dial gate checks the rest).
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_call_request_in_flight
    ON voice_live_call_request(workspace_id, destination_hash)
    WHERE state IN ('pending_approval', 'approved', 'dispatching');
CREATE INDEX IF NOT EXISTS voice_live_call_request_workspace
    ON voice_live_call_request(workspace_id, created_at DESC, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_call_request_session
    ON voice_live_call_request(live_session_id) WHERE live_session_id IS NOT NULL;

-- The end of the calling window a live session was admitted into (Admission::window_end of the pre-dial gate).
-- The session driver hangs the call up when it passes, so a call that starts inside the calling hours cannot go
-- on after they end. NULL: no window was recorded for the session (an inbound session).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS window_ends_at TIMESTAMPTZ;

-- Human review queue of the live path: what needs a person's decision. A row holds references and a short
-- machine-readable reason only, never transcript text, CRM data or a number. delegation_id is '' for a
-- session-level item (an opt-out heard on the call). Approving a dnc_request or opt_out item adds the
-- destination of the session's call request to voice_suppression (a human action); the other kinds are
-- acknowledged only.
CREATE TABLE IF NOT EXISTS voice_live_review (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL DEFAULT '' CHECK (char_length(delegation_id) <= 256),
    kind TEXT NOT NULL CHECK (kind IN ('dnc_request', 'opt_out', 'disallowed_op', 'screened_output')),
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'dismissed')),
    reason TEXT CHECK (char_length(reason) BETWEEN 1 AND 128),
    tool_execution_id UUID,
    decided_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    decided_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id, kind),
    CHECK ((status = 'open') = (decided_at IS NULL)),
    CHECK (status = 'open' OR decided_by IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS voice_live_review_workspace
    ON voice_live_review(workspace_id, status, created_at DESC, id DESC);

-- Mirror of packages/migration/migrations/060_drop_legacy_voice.sql.
-- Drops the legacy carrier voice schema. DESTRUCTIVE: every table, column and function below belonged to
-- the removed Twilio/Telnyx ConversationRelay path and its dialer; voice was never in production, so nothing
-- is archived. GPT-Live (voice_live_*, voice_agent_setting, voice_crm_binding, voice_delegation), the calling
-- policy, suppression, call lists (the lead source), inbound reception policy/blocks/attempts, and
-- voice_settings_audit stay. Idempotent: every statement is IF EXISTS / IF NOT EXISTS / OR REPLACE.

-- Inbound live sessions keep the caller's HMAC and last four digits so an admin can block a caller from the
-- session list (the number itself is never stored). They replace voice_call.caller_hash / caller_hint and are
-- purged with the inbound retention (voice::reception::purge_expired).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS caller_hash TEXT
    CHECK (caller_hash ~ '^[a-f0-9]{64}$');
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS caller_hint TEXT
    CHECK (caller_hint ~ '^[0-9]{1,4}$');
-- A live session no longer points at a legacy call (the column's composite FK and index go with it).
DROP INDEX IF EXISTS voice_live_session_call;
ALTER TABLE voice_live_session DROP COLUMN IF EXISTS voice_call_id;

-- The lead rules without the rules that read legacy calls (`unknown_outcome`, `already_called`).
-- voice::live::gate::lead_refusal still calls this function.
CREATE OR REPLACE FUNCTION voice_unattended_refusal(p_workspace UUID, p_entry UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN e.id IS NULL OR l.id IS NULL THEN 'entry_not_found'
        WHEN l.archived_at IS NOT NULL THEN 'list_archived'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') IN ('do_not_contact', 'opted_out')
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'dnc') THEN 'do_not_call'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') = 'call_not_interested'
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'blacklist') THEN 'blacklisted'
        WHEN e.status = 'callback'
            OR voice_lead_status(e.lead_context #>> '{lead,status}') IN ('call_callback', 'callback', '折り返し希望')
            THEN 'callback'
        WHEN e.status <> 'pending' THEN 'not_pending'
        WHEN NULLIF(btrim(e.lead_context #>> '{lead,lead_id}'), '') IS NULL THEN 'no_lead_id'
    END
    FROM (SELECT 1) AS one
    LEFT JOIN voice_call_list_entry e ON e.workspace_id = p_workspace AND e.id = p_entry
    LEFT JOIN voice_call_list l ON l.id = e.list_id AND l.workspace_id = e.workspace_id
$$;

-- Children first. Triggers go with their tables; no CASCADE is needed.
DROP TABLE IF EXISTS voice_business_result_evidence;
DROP TABLE IF EXISTS voice_business_result;
DROP TABLE IF EXISTS voice_tool_execution;
DROP TABLE IF EXISTS voice_provider_event;
DROP TABLE IF EXISTS voice_inbound_event;
DROP TABLE IF EXISTS voice_inbound_summary;
DROP TABLE IF EXISTS voice_envelope_replay;
DROP TABLE IF EXISTS voice_place_request;
DROP TABLE IF EXISTS voice_call;
DROP TABLE IF EXISTS voice_provider_connection;
DROP TABLE IF EXISTS voice_service_grant;
DROP TABLE IF EXISTS voice_workspace_setting;

DROP FUNCTION IF EXISTS voice_business_result_evidence_complete();
DROP FUNCTION IF EXISTS voice_business_result_immutable();
DROP FUNCTION IF EXISTS voice_business_result_project();
DROP FUNCTION IF EXISTS voice_business_result_projection_guard();
DROP FUNCTION IF EXISTS voice_business_result_tool_receipt_guard();
DROP FUNCTION IF EXISTS voice_call_gateway_snapshot_immutable();
DROP FUNCTION IF EXISTS voice_inbound_snapshot_immutable();
DROP FUNCTION IF EXISTS voice_place_request_guard();

-- Call lists: the auto-dial settings and the dialer's bookkeeping on entries. The live path refuses the
-- auto_dial origin explicitly and records its attempts in voice_live_call_request.
ALTER TABLE voice_call_list DROP CONSTRAINT IF EXISTS voice_call_list_auto_dial_owner;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_enabled;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_daily_cap;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_updated_by;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_updated_at;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS last_call_id;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS attempts;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS cleanup_reason;

-- The inbound turn workflow was stored for the admin view only; the live path never ran it.
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS inbound_workflow_id;
-- Superseded by voice_agent_setting.opt_out_adds_dnc (default OFF), which the live path reads; caller
-- matching against call lists was part of the legacy inbound summary (C1/C3), which the live path does not do.
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS match_call_lists;
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS opt_out_adds_dnc;

-- Mirror of packages/migration/migrations/061_add_voice_live_post_call.sql.
-- Durable post-call processing and the call outcome of a GPT-Live session. Additive; idempotent.
--
-- post_call_*: the post-call job of a session that ended (closed or lost), queued by the same UPDATE that
-- makes the session terminal and run by the live poller with its own lease (lease_owner / lease_expires_at
-- must stay NULL on a terminal session, see 057). NULL post_call_state: no job (a live session, a failed one,
-- or a session that ended before this migration; old calls are never re-run).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_state TEXT
    CHECK (post_call_state IN ('pending', 'running', 'done', 'failed'));
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_attempts INTEGER NOT NULL DEFAULT 0
    CHECK (post_call_attempts >= 0);
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_next_at TIMESTAMPTZ;
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_lease_expires_at TIMESTAMPTZ;
-- A short machine-readable code of the last failure, never an error message.
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_error TEXT
    CHECK (char_length(post_call_error) <= 64);
-- The CRM lead an inbound caller's number matched, sealed like the transcript (VoiceKeys::seal_live_secret,
-- field "lead_key:<session id>"). The post-call job may run on another replica than the one that took the call.
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS lead_key_enc TEXT
    CHECK (char_length(lead_key_enc) <= 2048);
-- The job query: jobs that are waiting or whose runner died.
CREATE INDEX IF NOT EXISTS voice_live_session_post_call ON voice_live_session(post_call_next_at, created_at)
    WHERE post_call_state IN ('pending', 'running');

-- A follow-up item: a call a person must act on (urgent or needs_review output, a caller no CRM lead matches,
-- a CRM write that did not happen, no post_call workflow, a lost sideband, or a post-call job that failed).
ALTER TABLE voice_live_review DROP CONSTRAINT IF EXISTS voice_live_review_kind_check;
ALTER TABLE voice_live_review ADD CONSTRAINT voice_live_review_kind_check
    CHECK (kind IN ('dnc_request', 'opt_out', 'disallowed_op', 'screened_output', 'follow_up'));

-- What the post_call workflow made of a call, kept independent of the CRM so a caller who matches no lead
-- is not lost. summary and next_action are AES-256-GCM ciphertext (VoiceKeys::seal_live_secret, fields
-- "outcome_summary:<session id>" and "outcome_next_action:<session id>"), never plaintext. status is a
-- short code. Purged with the transcript (voice::live::worker::purge_expired_call_data).
CREATE TABLE IF NOT EXISTS voice_live_call_outcome (
    live_session_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    encrypted_summary TEXT CHECK (char_length(encrypted_summary) BETWEEN 1 AND 16384),
    encrypted_next_action TEXT CHECK (char_length(encrypted_next_action) BETWEEN 1 AND 16384),
    status TEXT CHECK (char_length(status) <= 64),
    callback_at TIMESTAMPTZ,
    needs_follow_up BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS voice_live_call_outcome_workspace
    ON voice_live_call_outcome(workspace_id, created_at);

-- Mirror of packages/migration/migrations/062_add_voice_agent_service_tier.sql.
-- Processing tier for the GPT-Live delegation models. Existing rows stay on standard so a
-- deploy does not start billing the Fast premium by itself. The admin UI defaults a new
-- fast model to Fast; Ultrafast is only meaningful for the models that offer it.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS fast_service_tier TEXT NOT NULL DEFAULT 'standard'
    CHECK (fast_service_tier IN ('standard', 'fast', 'ultrafast'));
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS slow_service_tier TEXT NOT NULL DEFAULT 'standard'
    CHECK (slow_service_tier IN ('standard', 'fast', 'ultrafast'));

-- Mirror of packages/migration/migrations/064_add_voice_auto_hangup_settings.sql.
-- Auto-hangup is OFF for both directions so a deploy does not change how a call ends. The inbound
-- maximum call length is now enforced; the new default is 600 s and the range 30..1800 s. Existing
-- policy rows keep the value they have.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS auto_hangup_inbound BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS auto_hangup_outbound BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS idle_prompt_after_seconds INTEGER NOT NULL DEFAULT 15
    CHECK (idle_prompt_after_seconds BETWEEN 5 AND 60);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS idle_max_prompts INTEGER NOT NULL DEFAULT 2
    CHECK (idle_max_prompts BETWEEN 1 AND 5);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS closing_grace_seconds INTEGER NOT NULL DEFAULT 6
    CHECK (closing_grace_seconds BETWEEN 3 AND 15);

ALTER TABLE voice_inbound_policy ALTER COLUMN max_duration_seconds SET DEFAULT 600;
ALTER TABLE voice_inbound_policy DROP CONSTRAINT IF EXISTS voice_inbound_policy_max_duration_seconds_check;
ALTER TABLE voice_inbound_policy ADD CONSTRAINT voice_inbound_policy_max_duration_seconds_check
    CHECK (max_duration_seconds BETWEEN 30 AND 1800);

-- Mirror of packages/migration/migrations/065_add_voice_end_reason_and_grace.sql.
-- Grace period after the inbound maximum call length, and the reason an auto-hangup ended a live
-- session. After the limit the call waits up to the grace period for a natural break before the
-- agent apologises and the call is cut; the reason lets the post-call job tell the two apart.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS max_duration_grace_seconds INTEGER NOT NULL DEFAULT 60
    CHECK (max_duration_grace_seconds BETWEEN 0 AND 300);
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS end_reason TEXT;

-- Mirror of packages/migration/migrations/066_add_voice_telnyx_bridge.sql.
-- Outbound B-hybrid: Telnyx dials the callee, d6e then bridges the call to OpenAI once. Strictly
-- additive and idempotent. The default provider stays 'openai_direct' (today's path), so a deploy
-- changes nothing until a connection is switched; the previous image keeps working on this schema.
ALTER TABLE voice_live_connection ADD COLUMN IF NOT EXISTS outbound_provider TEXT NOT NULL DEFAULT 'openai_direct'
    CHECK (outbound_provider IN ('openai_direct', 'telnyx_bridge'));
-- Telnyx Call Control application id (not a secret); required when outbound_provider is 'telnyx_bridge'.
ALTER TABLE voice_live_connection ADD COLUMN IF NOT EXISTS telnyx_app_id TEXT
    CHECK (char_length(telnyx_app_id) BETWEEN 1 AND 128);

-- One row per bridged outbound request: the state of the two Telnyx legs (callee, OpenAI) until the
-- OpenAI webhook of the second leg is claimed and the session is registered. Holds no phone number:
-- the callee's number is only on the request (sealed). The token that correlates the OpenAI leg is
-- stored as its SHA-256; the session configuration waits here sealed and is deleted at the claim.
CREATE TABLE IF NOT EXISTS voice_live_bridge_call (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    request_id UUID NOT NULL REFERENCES voice_live_call_request(id) ON DELETE RESTRICT,
    state TEXT NOT NULL DEFAULT 'dialing' CHECK (state IN (
        'dialing', 'bridging', 'bridged', 'ended', 'no_answer', 'busy', 'rejected', 'failed', 'ambiguous', 'openai_failed'
    )),
    token_hash TEXT NOT NULL CHECK (token_hash ~ '^[a-f0-9]{64}$'),
    callee_call_control_id TEXT CHECK (char_length(callee_call_control_id) BETWEEN 1 AND 512),
    openai_call_control_id TEXT CHECK (char_length(openai_call_control_id) BETWEEN 1 AND 512),
    call_session_id TEXT CHECK (char_length(call_session_id) BETWEEN 1 AND 512),
    openai_session_id TEXT CHECK (char_length(openai_session_id) BETWEEN 1 AND 256),
    sealed_session TEXT CHECK (char_length(sealed_session) BETWEEN 1 AND 65536),
    window_ends_at TIMESTAMPTZ NOT NULL,
    deadline_at TIMESTAMPTZ NOT NULL,
    answered_at TIMESTAMPTZ,
    bridged_at TIMESTAMPTZ,
    amd_result TEXT CHECK (char_length(amd_result) <= 64),
    hangup_cause TEXT CHECK (char_length(hangup_cause) <= 64),
    hangup_source TEXT CHECK (char_length(hangup_source) <= 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (request_id)
);
CREATE INDEX IF NOT EXISTS voice_live_bridge_call_open
    ON voice_live_bridge_call(connection_id, deadline_at) WHERE state IN ('dialing', 'bridging', 'bridged');
CREATE INDEX IF NOT EXISTS voice_live_bridge_call_token ON voice_live_bridge_call(token_hash);

-- Outbound pre-dial: see migrations/067_add_voice_bridge_predial.sql 068_add_voice_bridge_openai_dropped.sql and 069_add_voice_bridge_sip_hangup_cause.sql.
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS predial BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_accepted_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_claimed_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_answered_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_done_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_attempt_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_dropped_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS callee_sip_hangup_cause TEXT CHECK (char_length(callee_sip_hangup_cause) <= 64);
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_sip_hangup_cause TEXT CHECK (char_length(openai_sip_hangup_cause) <= 64);

-- Outbound duplicate-call window: see migrations/070_add_voice_calling_policy_dedup_window.sql.
-- How long after a live call was placed another one to the same number or lead is refused as a
-- duplicate. 0 turns the period check off; a call still starting or in progress is refused
-- regardless.
ALTER TABLE voice_calling_policy
    ADD COLUMN IF NOT EXISTS dedup_window_minutes INTEGER NOT NULL DEFAULT 30
        CHECK (dedup_window_minutes BETWEEN 0 AND 1440);

-- Mirror of packages/migration/migrations/071_add_voice_session_context_enc.sql.
-- Sealed session context for a sideband that is not the process that registered the call.
-- Lite already stores this column. Full's API still passes context in memory; the column is
-- nullable so existing rows stay valid, and a separate sideband process (Lite's resident
-- `d6e-voice-sideband`) can open it after a claim.

ALTER TABLE voice_live_session
    ADD COLUMN IF NOT EXISTS session_context_enc TEXT
        CHECK (session_context_enc IS NULL OR char_length(session_context_enc) <= 65536);

-- A LiveKit inbound call uses the same voice_live_session row as GPT-Live, so post-call and
-- history stay on the internal id. The room name stays in voice_livekit_call. GPT-Live rows
-- still require openai_session_id. LiveKit rows leave it null. A room name is not unique: a
-- later call may reuse the name of a call that ended, so the app keeps one live session per room.

ALTER TABLE voice_live_connection
    ADD COLUMN IF NOT EXISTS conversation_runtime TEXT NOT NULL DEFAULT 'gpt_live'
        CHECK (conversation_runtime IN ('gpt_live', 'livekit'));

ALTER TABLE voice_live_session
    ADD COLUMN IF NOT EXISTS conversation_runtime TEXT NOT NULL DEFAULT 'gpt_live'
        CHECK (conversation_runtime IN ('gpt_live', 'livekit'));

ALTER TABLE voice_live_session ALTER COLUMN openai_session_id DROP NOT NULL;

ALTER TABLE voice_live_session DROP CONSTRAINT IF EXISTS voice_live_session_runtime_session_id;
ALTER TABLE voice_live_session ADD CONSTRAINT voice_live_session_runtime_session_id CHECK (
    (conversation_runtime = 'gpt_live' AND openai_session_id IS NOT NULL)
    OR (conversation_runtime = 'livekit' AND openai_session_id IS NULL)
);

CREATE TABLE IF NOT EXISTS voice_livekit_call (
    session_id UUID PRIMARY KEY REFERENCES voice_live_session(id) ON DELETE RESTRICT,
    workspace_id UUID NOT NULL,
    room_name TEXT NOT NULL CHECK (char_length(room_name) BETWEEN 1 AND 128),
    sip_participant_id TEXT CHECK (sip_participant_id IS NULL OR char_length(sip_participant_id) BETWEEN 1 AND 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT
);
-- The first revision of this migration made room_name UNIQUE: a database that ran it drops that here.
ALTER TABLE voice_livekit_call DROP CONSTRAINT IF EXISTS voice_livekit_call_room_name_key;
CREATE INDEX IF NOT EXISTS voice_livekit_call_room ON voice_livekit_call(room_name);

-- The business id of one delegation, `{live_session_id}:{delegation_id}`.
-- Existing rows are filled here. The handler writes the id the conversation service recorded
-- when a delegation finishes. Callers that insert a row must supply the same id.

ALTER TABLE voice_delegation ADD COLUMN IF NOT EXISTS operation_id TEXT;

UPDATE voice_delegation
SET operation_id = live_session_id::text || ':' || delegation_id
WHERE operation_id IS NULL;

ALTER TABLE voice_delegation ALTER COLUMN operation_id SET NOT NULL;

ALTER TABLE voice_delegation DROP CONSTRAINT IF EXISTS voice_delegation_operation_id_length;
ALTER TABLE voice_delegation ADD CONSTRAINT voice_delegation_operation_id_length
    CHECK (char_length(operation_id) BETWEEN 1 AND 320);

-- Whether the conversation service saw the delegation reply acknowledged or rejected.
-- Existing rows stay `pending`. The handler writes `acknowledged` or `failed` from that service.

ALTER TABLE voice_delegation ADD COLUMN IF NOT EXISTS command_state TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE voice_delegation DROP CONSTRAINT IF EXISTS voice_delegation_command_state_check;
ALTER TABLE voice_delegation ADD CONSTRAINT voice_delegation_command_state_check
    CHECK (command_state IN ('pending', 'acknowledged', 'failed'));


-- A process that has not been restarted still inserts voice_delegation without
-- operation_id. Fill `{live_session_id}:{delegation_id}` so that insert keeps
-- the same business id the new handler writes. A supplied id is left as it is.

CREATE OR REPLACE FUNCTION voice_delegation_set_operation_id() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.operation_id IS NULL OR length(btrim(NEW.operation_id)) = 0 THEN
        NEW.operation_id := NEW.live_session_id::text || ':' || NEW.delegation_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS voice_delegation_set_operation_id ON voice_delegation;
CREATE TRIGGER voice_delegation_set_operation_id BEFORE INSERT ON voice_delegation
FOR EACH ROW EXECUTE FUNCTION voice_delegation_set_operation_id();


-- Mirror of packages/migration/migrations/077_add_voice_call_request_purpose.sql.
-- Optional purpose of an outbound call request (written by whoever asked for the call, a Bot's AI for
-- example). It is encrypted by the API (AES-GCM bound to the workspace, `p1:` prefix), shown in full to
-- the admin who approves the call, and used only for that call. `purpose_hash` (HMAC) lets an idempotent
-- repeat be compared without decrypting. The text the approver saw is the text that is used: after the
-- row is created the two columns can only be cleared together (retention), never changed.
ALTER TABLE voice_live_call_request ADD COLUMN IF NOT EXISTS encrypted_purpose TEXT;
ALTER TABLE voice_live_call_request ADD COLUMN IF NOT EXISTS purpose_hash TEXT;

ALTER TABLE voice_live_call_request DROP CONSTRAINT IF EXISTS voice_live_call_request_purpose_check;
ALTER TABLE voice_live_call_request ADD CONSTRAINT voice_live_call_request_purpose_check CHECK (
    (encrypted_purpose IS NULL AND purpose_hash IS NULL)
    OR (
        encrypted_purpose LIKE 'p1:%'
        AND char_length(encrypted_purpose) BETWEEN 4 AND 4096
        AND purpose_hash ~ '^[a-f0-9]{64}$'
    )
);

CREATE OR REPLACE FUNCTION voice_live_call_request_purpose_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.encrypted_purpose IS DISTINCT FROM OLD.encrypted_purpose
        OR NEW.purpose_hash IS DISTINCT FROM OLD.purpose_hash)
       AND NOT (NEW.encrypted_purpose IS NULL AND NEW.purpose_hash IS NULL) THEN
        RAISE EXCEPTION 'voice_live_call_request purpose cannot be changed after creation'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS voice_live_call_request_purpose_guard ON voice_live_call_request;
CREATE TRIGGER voice_live_call_request_purpose_guard
    BEFORE UPDATE OF encrypted_purpose, purpose_hash ON voice_live_call_request
    FOR EACH ROW EXECUTE FUNCTION voice_live_call_request_purpose_guard();


-- Mirror of packages/migration/migrations/078_add_voice_outbound_workflows.sql.
-- Separate workflows for outbound calls, so one workspace can run an inbound plugin (for example
-- d6e/voice-inbound) and an outbound plugin (d6e/voice-outbound) side by side.
--   outbound_*_workflow_id  used for outbound calls when set.
--   outbound_opening        the outbound opening, overriding the plugin's (as `opening` does).
--   outbound_separate       false (default, as before): an outbound slot left empty uses the shared
--                           workflow (and the shared opening). true: outbound calls use only the
--                           outbound slots; an empty one means none, so an inbound workflow is never
--                           run for an outbound call.
-- Inbound calls keep using the shared columns. Existing rows behave as before.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_context_workflow_id UUID
    CHECK (outbound_context_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_delegate_workflow_id UUID
    CHECK (outbound_delegate_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_post_call_workflow_id UUID
    CHECK (outbound_post_call_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_opening TEXT
    CHECK (char_length(outbound_opening) BETWEEN 1 AND 1000);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_separate BOOLEAN NOT NULL DEFAULT FALSE;
