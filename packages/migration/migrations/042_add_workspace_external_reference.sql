-- Stable, product-scoped workspace identity for trusted external provisioners.
-- The row outlives ordinary setup retries and prevents ambiguous POST retries
-- from creating multiple workspaces for the same external organization.

CREATE TABLE IF NOT EXISTS workspace_external_reference (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    namespace TEXT NOT NULL CHECK (
        namespace ~ '^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?$'
    ),
    external_organization_id UUID NOT NULL,
    created_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workspace_external_reference_identity_unique
        UNIQUE(namespace, external_organization_id)
);

