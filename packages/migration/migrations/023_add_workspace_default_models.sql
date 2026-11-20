-- Migration: Add workspace_default_models table.
-- Stores per-workspace default model selections for two surfaces:
--   * chat_*: initial model selection for the chat UI (used when the user
--     has no explicit choice in their IndexedDB llm-settings).
--   * sns_*:  default model used when the SNS bot pipeline (Slack / Discord
--     / LINE → /api/workflows/execute-by-intent) starts a conversation.
--
-- Design notes:
-- - All columns are NOT NULL with sensible defaults. There is no concept of
--   "unset" — workspace admins always pick something or leave the seeded
--   anthropic / claude-sonnet-4-6 default in place.
-- - A backfill INSERT seeds every existing workspace with the default pair,
--   so callers can rely on the row existing. The frontend loader still has
--   a lazy fallback in case a row is somehow missing (defensive coding).
-- - On workspace creation, the frontend explicitly inserts a row pointing at
--   the same defaults so brand-new workspaces also have a row immediately.

CREATE TABLE IF NOT EXISTS frontend.workspace_default_models (
    workspace_id  UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    chat_provider TEXT NOT NULL DEFAULT 'anthropic',
    chat_model    TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
    sns_provider  TEXT NOT NULL DEFAULT 'anthropic',
    sns_model     TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Backfill: every existing workspace gets a row with the default pair so
-- runtime code can assume the row exists.
INSERT INTO frontend.workspace_default_models (workspace_id)
SELECT id FROM workspace
ON CONFLICT (workspace_id) DO NOTHING;
