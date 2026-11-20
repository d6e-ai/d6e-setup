-- Store one write-only d6e AI Gateway project-scoped virtual key per
-- workspace. A missing row means the workspace continues to use the existing
-- Vercel AI Gateway route. Runtime route selection is introduced separately
-- so no workspace can switch before every AI call path uses the same resolver.

CREATE TABLE IF NOT EXISTS frontend.workspace_d6e_ai_gateway_credential (
    workspace_id          UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    encrypted_virtual_key TEXT NOT NULL,
    key_hint              TEXT NOT NULL,
    verified_at           TIMESTAMPTZ NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
