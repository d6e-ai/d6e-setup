-- GPT-Live voice foundation (OpenAI Direct SIP + sideband). Strictly additive: new tables and indexes only.
-- d6e talks only to OpenAI in the new path; these tables hold the OpenAI connection and a webhook/sideband
-- event ledger. Retained audit data must not disappear with a workspace, hence ON DELETE RESTRICT.

-- One active OpenAI Live connection per workspace. Secrets are AES-256-GCM ciphertext (crate::crypto via
-- voice::privacy::VoiceKeys) and are never returned by any API. A soft-deleted row keeps its id so the
-- event ledger below can still reference it, but its secrets are wiped (NULL once deleted_at is set).
CREATE TABLE IF NOT EXISTS voice_live_connection (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    openai_project_id TEXT NOT NULL CHECK (openai_project_id LIKE 'proj\_%' AND char_length(openai_project_id) <= 128),
    -- 'instance': use the D6E_VOICE_OPENAI_* values of the deployment. 'workspace': use the secrets below.
    key_source TEXT NOT NULL CHECK (key_source IN ('instance', 'workspace')),
    encrypted_api_key TEXT CHECK (char_length(encrypted_api_key) BETWEEN 1 AND 8192),
    api_key_hint TEXT CHECK (char_length(api_key_hint) <= 64),
    encrypted_webhook_secret TEXT CHECK (char_length(encrypted_webhook_secret) BETWEEN 1 AND 8192),
    sip_provider_url TEXT NOT NULL CHECK (sip_provider_url LIKE 'sips:%' AND char_length(sip_provider_url) <= 255),
    encrypted_trunk_username TEXT CHECK (char_length(encrypted_trunk_username) BETWEEN 1 AND 8192),
    encrypted_trunk_password TEXT CHECK (char_length(encrypted_trunk_password) BETWEEN 1 AND 8192),
    caller_number TEXT NOT NULL CHECK (caller_number ~ '^\+[1-9][0-9]{7,14}$'),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    -- While the connection is live, workspace-held secrets are required exactly when the workspace is
    -- the key source, and the trunk credentials are always required.
    CHECK (
        deleted_at IS NOT NULL
        OR (
            encrypted_trunk_username IS NOT NULL
            AND encrypted_trunk_password IS NOT NULL
            AND (
                (key_source = 'workspace' AND encrypted_api_key IS NOT NULL AND encrypted_webhook_secret IS NOT NULL)
                OR (key_source = 'instance' AND encrypted_api_key IS NULL AND encrypted_webhook_secret IS NULL)
            )
        )
    )
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_connection_workspace_active
    ON voice_live_connection(workspace_id) WHERE deleted_at IS NULL;

-- Dedup ledger for OpenAI webhook deliveries and sideband events. Only the event type, session id and a
-- payload hash are kept: never raw SIP headers, phone numbers or bodies.
CREATE TABLE IF NOT EXISTS voice_live_event (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    source TEXT NOT NULL CHECK (source IN ('webhook', 'sideband')),
    event_id TEXT NOT NULL CHECK (char_length(event_id) BETWEEN 1 AND 256),
    event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 128),
    session_id TEXT CHECK (char_length(session_id) <= 256),
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload_hash TEXT NOT NULL CHECK (payload_hash ~ '^[a-f0-9]{64}$'),
    UNIQUE (connection_id, source, event_id)
);
CREATE INDEX IF NOT EXISTS voice_live_event_workspace ON voice_live_event(workspace_id, received_at DESC);
