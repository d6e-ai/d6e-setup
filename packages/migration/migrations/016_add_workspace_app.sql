-- Workspace App table for marketplace app installations.
--
-- Tracks installed apps per workspace, including their version, manifest URL,
-- trust tier, template prompt (injected into chat system prompt), and
-- installed API resources (STFs, files, effects, workflows) as JSONB for
-- cleanup on uninstall.
--
-- Constraints:
-- - (workspace_id, app_namespace, app_name) is unique — one install per app per workspace
-- - installed_resources is nullable (apps without resources)
-- - template_prompt is nullable (apps without prompts)
-- - tier is 'verified' or 'unverified', sourced from the trusted registry index

CREATE TABLE IF NOT EXISTS frontend.workspace_app (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    app_namespace TEXT NOT NULL,
    app_name TEXT NOT NULL,
    installed_version TEXT NOT NULL,
    manifest_url TEXT NOT NULL,
    tier TEXT NOT NULL CHECK (tier IN ('verified', 'unverified')),
    template_prompt TEXT,
    installed_resources JSONB,
    installed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(workspace_id, app_namespace, app_name)
);

CREATE INDEX IF NOT EXISTS idx_frontend_workspace_app_workspace
    ON frontend.workspace_app(workspace_id);
