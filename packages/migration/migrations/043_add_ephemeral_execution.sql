-- Durable metadata for one-shot executions in registered runtime profiles.
-- Raw argv, environment values, signed URLs, and credentials are never stored.

CREATE TABLE IF NOT EXISTS frontend.ephemeral_execution (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    runtime_profile TEXT NOT NULL,
    profile_snapshot JSONB NOT NULL,
    idempotency_key_digest TEXT NOT NULL,
    request_fingerprint TEXT NOT NULL,
    provider_execution_id TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'provisioning' CHECK (
        status IN ('provisioning', 'running', 'succeeded', 'failed', 'cancelled')
    ),
    cancel_requested_at TIMESTAMPTZ,
    exit_code INTEGER,
    failure_code TEXT CHECK (
        failure_code IS NULL OR failure_code IN (
            'launch_rejected', 'launch_unresolved', 'deadline_exceeded', 'runtime_failed'
        )
    ),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ephemeral_execution_workspace_idempotency_unique
        UNIQUE (workspace_id, idempotency_key_digest)
);

CREATE INDEX IF NOT EXISTS idx_ephemeral_execution_workspace_created
    ON frontend.ephemeral_execution(workspace_id, created_at DESC);

-- Experimental cost guardrail: one in-flight execution per workspace/profile.
CREATE UNIQUE INDEX IF NOT EXISTS ephemeral_execution_workspace_profile_active_unique
    ON frontend.ephemeral_execution(workspace_id, runtime_profile)
    WHERE status IN ('provisioning', 'running');
