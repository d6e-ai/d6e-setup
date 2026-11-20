-- Migration: Extend frontend.workspace_chat_template with sidebar nav labels
-- and completed-tasks page section heading overrides.
--
-- Adds four optional TEXT columns. All NULL by default so the existing rows
-- continue to fall back to the built-in i18n strings without any visible
-- change. Set explicitly (via the admin Settings UI or the d6e_* MCP tools)
-- to override the corresponding label per workspace:
--   - nav_label_agents: overrides the "AI Agent" sidebar entry label.
--   - nav_label_tasks: overrides the new "Completed tasks" sidebar entry
--     label (the entry itself is always shown).
--   - task_ai_answer_label: section heading shown above the latest AI
--     response on the completed-tasks detail panel. Default i18n string is
--     "AI response" / "AI回答".
--   - task_learning_label: section heading shown above the user_memory
--     entries learned during that session. Default i18n string is
--     "Learning notes" / "学習内容".
--
-- A separate "Help" sidebar entry is intentionally NOT modelled here: the
-- existing quick_actions JSONB column already supports an arbitrary
-- shortcut, and the tutorial prompts now recommend adding a "Help" quick
-- action with the new HelpCircle icon instead of paying for a dedicated
-- column.
--
-- All columns are backwards compatible: pre-existing templates keep
-- rendering the default labels until explicitly updated.

ALTER TABLE frontend.workspace_chat_template
    ADD COLUMN IF NOT EXISTS nav_label_agents TEXT,
    ADD COLUMN IF NOT EXISTS nav_label_tasks TEXT,
    ADD COLUMN IF NOT EXISTS task_ai_answer_label TEXT,
    ADD COLUMN IF NOT EXISTS task_learning_label TEXT;
