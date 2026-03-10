-- D6E Database Schema
-- This file is used by tests and setup-db.sh

-- Enable pgvector extension for vector similarity search (optional)
-- Silently skip if the extension is not available (e.g. vanilla postgres in tests)
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
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS workspace_membership (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    role workspace_role NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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

-- frontend スキーマ (フロントエンド専用データ用)
CREATE SCHEMA IF NOT EXISTS frontend;

-- Chat sessions for AI agent conversations
CREATE TABLE IF NOT EXISTS frontend.chat_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    title TEXT,
    messages JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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

-- LLM usage tracking
CREATE TABLE IF NOT EXISTS frontend.llm_usage (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL,
    user_id UUID NOT NULL,
    chat_session_id UUID REFERENCES frontend.chat_session(id),
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    total_tokens INTEGER NOT NULL,
    estimated_cost_usd NUMERIC(10, 6),
    request_type TEXT,
    tools_used TEXT[],
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_workspace ON frontend.chat_session(workspace_id);
CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_updated_at ON frontend.chat_session(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_frontend_mcp_server_workspace ON frontend.mcp_server(workspace_id);
CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_workspace ON frontend.llm_usage(workspace_id);
CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_user ON frontend.llm_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_created_at ON frontend.llm_usage(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_frontend_llm_usage_provider_model ON frontend.llm_usage(provider, model);

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
    hallucination_verification_enabled BOOLEAN NOT NULL DEFAULT true,
    verification_provider TEXT NOT NULL DEFAULT 'anthropic',
    verification_model TEXT NOT NULL DEFAULT 'claude-haiku-4-5',
    mcp_timeout_ms INTEGER NOT NULL DEFAULT 300000,
    sql_approval_mode TEXT NOT NULL DEFAULT 'write_only',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, workspace_id)
);

CREATE INDEX IF NOT EXISTS idx_user_workspace_settings_workspace 
    ON frontend.user_workspace_settings(workspace_id);

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
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, table_name, source_column)
);
