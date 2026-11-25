-- This server's own D6E AI key for the D6E AI entry (run by d6e.ai). The server
-- takes it from d6e.ai with its client credentials (POST /api/v1/ai/server-key)
-- when it has none or the entry refuses the one it has, and keeps it here,
-- encrypted with SAAS_CREDENTIAL_ENCRYPTION_KEY (the format of
-- workspace_d6e_ai_gateway_credential), so the web app and the API share one
-- key. One row at most. A workspace's own key
-- (frontend.workspace_d6e_ai_gateway_credential) takes precedence.
--   key_id       d6e.ai's id of the key, compared when the entry refuses a key
--                so that two processes do not both take a new one.
--   key_hint     d6e_ai_{environment}_{public id}_…{last 4}, never the key.
--   environment  live, or test (reaches only the entry's mock upstream).

CREATE TABLE IF NOT EXISTS frontend.instance_ai_entry_key (
    id            BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    encrypted_key TEXT NOT NULL,
    key_id        TEXT NOT NULL CHECK (char_length(key_id) BETWEEN 1 AND 128),
    key_hint      TEXT NOT NULL CHECK (char_length(key_hint) BETWEEN 1 AND 128),
    environment   TEXT NOT NULL CHECK (environment IN ('live', 'test')),
    obtained_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
