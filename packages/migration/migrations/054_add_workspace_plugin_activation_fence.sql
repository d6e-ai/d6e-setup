-- Monotonic revision for conditional machine Plugin setup. Kept separately
-- from installed Plugin metadata so uninstalling a Plugin does not reset it.
CREATE TABLE IF NOT EXISTS frontend.workspace_plugin_activation_fence (
    workspace_id UUID NOT NULL,
    plugin_namespace TEXT NOT NULL,
    plugin_name TEXT NOT NULL,
    activation_revision BIGINT NOT NULL,
    requested_version TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (workspace_id, plugin_namespace, plugin_name),
    CONSTRAINT workspace_plugin_activation_fence_revision_check CHECK (
        activation_revision > 0 AND activation_revision <= 9007199254740991
    )
);
