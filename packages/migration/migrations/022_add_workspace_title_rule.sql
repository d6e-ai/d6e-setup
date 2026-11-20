-- Migration: Add workspace_title_rule table.
-- Stores a single per-workspace naming guideline used by the chat session
-- title generator. Kept separate from workspace_prompt_rule so the (often
-- large) main custom-prompt rules are not pulled into title-generation
-- prompts. Title generation is a high-frequency / low-token task and must
-- stay cheap.
--
-- Schema:
-- - workspace_id is the primary key; one rule per workspace at most.
-- - content is free-form text describing how titles should look (language,
--   prefix conventions, style, etc.).
-- - When no row exists for a workspace, the title generator falls back to
--   its built-in opencode-style prompt only.

CREATE TABLE IF NOT EXISTS frontend.workspace_title_rule (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
