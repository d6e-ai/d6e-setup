-- Migration: Add stf_secret table for encrypted environment variables.
--
-- Stores encrypted API keys and other secrets for Docker STF execution.
-- Values are AES-256-GCM encrypted using SAAS_CREDENTIAL_ENCRYPTION_KEY.
-- Designed as write-only: API never returns plaintext values.
--
-- Constraints:
-- - (stf_id, env_key) is unique — one value per key per STF
-- - ON DELETE CASCADE — secrets are auto-deleted when the parent STF is deleted
-- - env_key max length 255, encrypted_value is base64-encoded ciphertext

CREATE TABLE IF NOT EXISTS frontend.stf_secret (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    stf_id UUID NOT NULL REFERENCES state_transition_function(id) ON DELETE CASCADE,
    env_key TEXT NOT NULL CHECK (char_length(env_key) <= 255),
    encrypted_value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(stf_id, env_key)
);

CREATE INDEX IF NOT EXISTS idx_frontend_stf_secret_stf_id
    ON frontend.stf_secret(stf_id);
