-- Migration: Workspace-scoped custom Agent Skills (SKILL.md + references/assets)
-- Creates frontend.workspace_skill and frontend.workspace_skill_file tables.

CREATE TABLE IF NOT EXISTS frontend.workspace_skill (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    content TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    source TEXT NOT NULL DEFAULT 'manual',
    source_url TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, name)
);

CREATE INDEX IF NOT EXISTS idx_workspace_skill_workspace
    ON frontend.workspace_skill(workspace_id);

CREATE TABLE IF NOT EXISTS frontend.workspace_skill_file (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    skill_id UUID NOT NULL REFERENCES frontend.workspace_skill(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    kind TEXT NOT NULL,
    content TEXT,
    storage_file_id UUID REFERENCES storage_file(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (skill_id, path),
    CONSTRAINT workspace_skill_file_path_no_dotdot CHECK (path NOT LIKE '%..%')
);

CREATE INDEX IF NOT EXISTS idx_workspace_skill_file_skill
    ON frontend.workspace_skill_file(skill_id);
