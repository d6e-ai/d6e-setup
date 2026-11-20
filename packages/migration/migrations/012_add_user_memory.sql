-- Per-user, per-workspace memory entries extracted from conversations.
-- Stores facts and preferences that persist across chat sessions.

CREATE TABLE IF NOT EXISTS frontend.user_memory (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    content TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT 'preference',
    source_session_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_user_memory_content
    ON frontend.user_memory (user_id, workspace_id, content_hash);

CREATE INDEX IF NOT EXISTS ix_user_memory_user_workspace
    ON frontend.user_memory (user_id, workspace_id, updated_at DESC);

-- Add memory_enabled toggle to user_workspace_settings
ALTER TABLE frontend.user_workspace_settings
    ADD COLUMN IF NOT EXISTS memory_enabled BOOLEAN NOT NULL DEFAULT TRUE;
