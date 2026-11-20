-- Voice is additive. Ordinary identity, subscriptions and SaaS credentials are unchanged.
-- Retained call/audit data must not disappear when a workspace is removed.
CREATE TABLE IF NOT EXISTS voice_workspace_setting (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL CHECK (char_length(profile_ref) BETWEEN 1 AND 128),
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    max_duration_seconds INTEGER NOT NULL CHECK (max_duration_seconds BETWEEN 1 AND 300),
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    consent_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    consent_at TIMESTAMPTZ NOT NULL,
    settings_version BIGINT NOT NULL DEFAULT 1 CHECK (settings_version > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS voice_call (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    request_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    actor_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    request_hash TEXT NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL,
    profile_version TEXT NOT NULL,
    settings_version BIGINT NOT NULL,
    max_duration_seconds INTEGER NOT NULL CHECK (max_duration_seconds BETWEEN 1 AND 300),
    encrypted_destination TEXT,
    encrypted_nonce TEXT,
    auth_snapshot JSONB,
    state TEXT NOT NULL DEFAULT 'preparing' CHECK (state IN (
        'preparing', 'reservation_unknown', 'reserved', 'dispatching',
        'submission_unknown', 'submitted', 'ended', 'canceled', 'failed'
    )),
    business_state TEXT NOT NULL DEFAULT 'incomplete' CHECK (business_state IN (
        'incomplete', 'needs_review', 'succeeded', 'failed'
    )),
    provider_call_sid TEXT,
    provider_terminal BOOLEAN NOT NULL DEFAULT FALSE,
    start_before TIMESTAMPTZ,
    connect_before TIMESTAMPTZ,
    dispatch_attempted BOOLEAN NOT NULL DEFAULT FALSE,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    session_claimed BOOLEAN NOT NULL DEFAULT FALSE,
    session_generation BIGINT NOT NULL DEFAULT 0,
    turn_generation BIGINT NOT NULL DEFAULT 0 CHECK (turn_generation >= 0),
    session_owner UUID,
    lease_expires_at TIMESTAMPTZ,
    runtime_expires_at TIMESTAMPTZ,
    end_requested BOOLEAN NOT NULL DEFAULT FALSE,
    usage_pending BOOLEAN NOT NULL DEFAULT FALSE,
    suppression_pending BOOLEAN NOT NULL DEFAULT FALSE,
    runtime_reason TEXT CHECK (runtime_reason IN (
        'completed', 'recipient_request', 'runtime_failure', 'deadline', 'relay_disconnected'
    )),
    runtime_duration_seconds INTEGER NOT NULL DEFAULT 0 CHECK (runtime_duration_seconds BETWEEN 0 AND 300),
    cleanup_next_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, request_id),
    UNIQUE (id, workspace_id),
    CHECK (NOT provider_terminal OR (provider_call_sid IS NOT NULL AND state IN ('ended', 'canceled', 'failed'))),
    CHECK (NOT session_claimed OR (session_owner IS NOT NULL AND session_generation > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_workspace_active
    ON voice_call(workspace_id)
    WHERE state IN ('preparing', 'reservation_unknown', 'reserved', 'dispatching', 'submission_unknown', 'submitted');
CREATE INDEX IF NOT EXISTS voice_call_workspace_history ON voice_call(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS voice_call_cleanup ON voice_call(cleanup_next_at)
    WHERE end_requested OR usage_pending OR suppression_pending OR dispatch_attempted;

CREATE TABLE IF NOT EXISTS voice_provider_event (
    event_id UUID PRIMARY KEY,
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    state TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT
);
CREATE TABLE IF NOT EXISTS voice_envelope_replay (
    jti UUID PRIMARY KEY,
    purpose TEXT NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS voice_tool_execution (
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    execution_id UUID NOT NULL,
    capability TEXT NOT NULL,
    input_hash TEXT NOT NULL CHECK (input_hash ~ '^[a-f0-9]{64}$'),
    session_generation BIGINT NOT NULL,
    state TEXT NOT NULL DEFAULT 'started' CHECK (state IN ('started', 'completed', 'unknown')),
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (call_id, execution_id),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT
);
