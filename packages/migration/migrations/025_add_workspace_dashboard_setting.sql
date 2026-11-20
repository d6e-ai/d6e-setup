-- Migration: Add workspace_dashboard_setting table.
-- Stores a per-workspace boolean controlling whether the BI-style dashboard
-- (pinned charts, quick workflows) is shown as the workspace top page.
-- Kept in a dedicated table rather than as a column on `workspace` so the
-- frontend can manage it through Drizzle without requiring a SeaORM
-- migration on the API side.
--
-- Design notes:
-- - Mirrors the workspace_default_models pattern: workspace_id is the
--   primary key, and a backfill INSERT seeds every existing workspace with
--   the default value so callers can always assume the row exists.
-- - dashboard_enabled defaults to TRUE — preserves the existing behaviour
--   where every workspace shows the dashboard as the top page.
-- - When FALSE, the workspace top page redirects to the active chat
--   template (if any) or to the AI agent screen.

CREATE TABLE IF NOT EXISTS frontend.workspace_dashboard_setting (
    workspace_id      UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    dashboard_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Backfill: every existing workspace gets a row with dashboard_enabled=TRUE
-- so runtime code can assume the row exists.
INSERT INTO frontend.workspace_dashboard_setting (workspace_id)
SELECT id FROM workspace
ON CONFLICT (workspace_id) DO NOTHING;
