-- Migration: Extend frontend.workspace_chat_template with custom UI fields.
--
-- Adds five columns that drive the per-workspace landing experience improvements
-- requested in issue #313:
--   - greeting_message: optional bubble copy rendered above the title
--     (e.g. "今日は何しますか？").
--   - brand_name: optional large brand-style heading; falls back to `title`
--     when NULL (e.g. "AI経理 2026").
--   - hero_layout: switch between the existing compact layout and the new
--     hero layout. CHECK constraint enforces the union so a stray value
--     cannot break the renderer.
--   - quick_actions: JSON array of `{ label, prompt, icon? }` rendered as
--     sidebar shortcuts. Default empty array preserves the current sidebar.
--   - theme_accent: optional CSS theme preset key. NULL keeps the default
--     site theme. CHECK constraint pins the allowed presets.
--   - group_history_by_date: when TRUE, the sidebar groups history by
--     "Today / Yesterday / Earlier" instead of the flat list.
--
-- All columns are backwards compatible: existing rows keep the legacy
-- compact look unless an admin (or LLM via MCP) opts in to the new fields.

ALTER TABLE frontend.workspace_chat_template
    ADD COLUMN IF NOT EXISTS greeting_message TEXT,
    ADD COLUMN IF NOT EXISTS brand_name TEXT,
    ADD COLUMN IF NOT EXISTS hero_layout TEXT NOT NULL DEFAULT 'compact',
    ADD COLUMN IF NOT EXISTS quick_actions JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS theme_accent TEXT,
    ADD COLUMN IF NOT EXISTS group_history_by_date BOOLEAN NOT NULL DEFAULT FALSE;

-- Constrain hero_layout to the two known modes so a typo cannot quietly
-- disable the renderer (the SvelteKit launcher only branches on these
-- string literals).
ALTER TABLE frontend.workspace_chat_template
    DROP CONSTRAINT IF EXISTS workspace_chat_template_hero_layout_check;
ALTER TABLE frontend.workspace_chat_template
    ADD CONSTRAINT workspace_chat_template_hero_layout_check
        CHECK (hero_layout IN ('compact', 'hero'));

-- Pin theme_accent to the supported presets. NULL means "site default".
ALTER TABLE frontend.workspace_chat_template
    DROP CONSTRAINT IF EXISTS workspace_chat_template_theme_accent_check;
ALTER TABLE frontend.workspace_chat_template
    ADD CONSTRAINT workspace_chat_template_theme_accent_check
        CHECK (theme_accent IS NULL OR theme_accent IN
            ('green', 'blue', 'purple', 'orange', 'rose', 'slate'));
