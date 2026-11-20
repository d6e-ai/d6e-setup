-- Migration: Add saas_credential table and saas_credential_id FK to mcp_server.
-- Stores encrypted OAuth tokens and API keys for SaaS integrations.
-- Credentials are AES-256-GCM encrypted; only the API server decrypts them at runtime.

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
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(workspace_id, provider)
);

ALTER TABLE frontend.mcp_server
    ADD COLUMN IF NOT EXISTS saas_credential_id UUID
        REFERENCES frontend.saas_credential(id) ON DELETE SET NULL;
