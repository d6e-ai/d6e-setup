-- Migration: Add workspace_chat_template table.
-- Stores per-workspace chat frontend templates that act as a custom landing
-- screen (icon + title + description + upload card + history) shown on the
-- workspace top page when dashboards are disabled. At most one row per
-- workspace can be active (is_active = TRUE) at any time; that active
-- template is what the workspace top page renders. When no active template
-- exists, the top page falls back to the AI agent screen.
--
-- Schema:
-- - id: surrogate primary key.
-- - workspace_id: owning workspace; cascade-deletes when the workspace is
--   removed.
-- - name: admin-facing label of the template (e.g. "AI仕訳").
-- - icon / icon_gradient: optional logo glyph (1-2 chars or emoji) and CSS
--   gradient string used to paint the icon background.
-- - subtitle / title / description: marketing-style copy rendered above the
--   upload card. title is required, the others are optional.
-- - upload_card_*: copy for the file-drop card. upload_card_title and
--   upload_button_label are required; description is optional.
-- - history_section_title: when non-null and non-empty, a "recent chat
--   sessions" list is rendered under the upload card. NULL/empty hides it.
-- - send_instruction: prompt text appended to the chat when the user
--   submits files via the template. Required.
-- - accepted_file_types: MIME-type allow-list for the upload picker; default
--   accepts images and PDF.
-- - is_active: at most one active row per workspace (enforced by the unique
--   partial index below).

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
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workspace_chat_template_workspace
    ON frontend.workspace_chat_template(workspace_id);

-- At most one active template per workspace. Enforced via a partial unique
-- index over workspace_id where is_active = TRUE so multiple historic
-- templates can coexist while only one is "the standard".
CREATE UNIQUE INDEX IF NOT EXISTS uniq_workspace_chat_template_active
    ON frontend.workspace_chat_template(workspace_id)
    WHERE is_active = TRUE;
