-- Outbound B-hybrid: Telnyx dials the callee, d6e then bridges the call to OpenAI once. Strictly
-- additive and idempotent. The default provider stays 'openai_direct' (today's path), so a deploy
-- changes nothing until a connection is switched; the previous image keeps working on this schema.
ALTER TABLE voice_live_connection ADD COLUMN IF NOT EXISTS outbound_provider TEXT NOT NULL DEFAULT 'openai_direct'
    CHECK (outbound_provider IN ('openai_direct', 'telnyx_bridge'));
-- Telnyx Call Control application id (not a secret); required when outbound_provider is 'telnyx_bridge'.
ALTER TABLE voice_live_connection ADD COLUMN IF NOT EXISTS telnyx_app_id TEXT
    CHECK (char_length(telnyx_app_id) BETWEEN 1 AND 128);

-- One row per bridged outbound request: the state of the two Telnyx legs (callee, OpenAI) until the
-- OpenAI webhook of the second leg is claimed and the session is registered. Holds no phone number:
-- the callee's number is only on the request (sealed). The token that correlates the OpenAI leg is
-- stored as its SHA-256; the session configuration waits here sealed and is deleted at the claim.
CREATE TABLE IF NOT EXISTS voice_live_bridge_call (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    request_id UUID NOT NULL REFERENCES voice_live_call_request(id) ON DELETE RESTRICT,
    state TEXT NOT NULL DEFAULT 'dialing' CHECK (state IN (
        'dialing', 'bridging', 'bridged', 'ended', 'no_answer', 'busy', 'rejected', 'failed', 'ambiguous', 'openai_failed'
    )),
    token_hash TEXT NOT NULL CHECK (token_hash ~ '^[a-f0-9]{64}$'),
    callee_call_control_id TEXT CHECK (char_length(callee_call_control_id) BETWEEN 1 AND 512),
    openai_call_control_id TEXT CHECK (char_length(openai_call_control_id) BETWEEN 1 AND 512),
    call_session_id TEXT CHECK (char_length(call_session_id) BETWEEN 1 AND 512),
    openai_session_id TEXT CHECK (char_length(openai_session_id) BETWEEN 1 AND 256),
    sealed_session TEXT CHECK (char_length(sealed_session) BETWEEN 1 AND 65536),
    window_ends_at TIMESTAMPTZ NOT NULL,
    deadline_at TIMESTAMPTZ NOT NULL,
    answered_at TIMESTAMPTZ,
    bridged_at TIMESTAMPTZ,
    amd_result TEXT CHECK (char_length(amd_result) <= 64),
    hangup_cause TEXT CHECK (char_length(hangup_cause) <= 64),
    hangup_source TEXT CHECK (char_length(hangup_source) <= 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (request_id)
);
CREATE INDEX IF NOT EXISTS voice_live_bridge_call_open
    ON voice_live_bridge_call(connection_id, deadline_at) WHERE state IN ('dialing', 'bridging', 'bridged');
CREATE INDEX IF NOT EXISTS voice_live_bridge_call_token ON voice_live_bridge_call(token_hash);
