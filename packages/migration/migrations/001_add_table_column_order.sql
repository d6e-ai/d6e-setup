-- Migration: Add table_column_order table
-- Stores per-user, per-workspace, per-table column display ordering preferences.

CREATE TABLE IF NOT EXISTS frontend.table_column_order (
    user_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    column_order JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, workspace_id, table_name)
);
