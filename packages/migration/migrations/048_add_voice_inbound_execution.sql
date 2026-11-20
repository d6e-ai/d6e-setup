-- Incoming authority belongs to the workspace; approval attribution is audit only.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS inbound_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS inbound_live_approved BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS voice_service_grant (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    configuration_version INTEGER NOT NULL CHECK (configuration_version > 0),
    profile_ref TEXT NOT NULL CHECK (char_length(profile_ref) BETWEEN 1 AND 128),
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    capabilities JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(capabilities) = 'array'),
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    revoked_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    grant_version BIGINT NOT NULL DEFAULT 1 CHECK (grant_version > 0),
    approved_settings_version BIGINT NOT NULL CHECK (approved_settings_version > 0),
    settings_fingerprint TEXT NOT NULL CHECK (settings_fingerprint ~ '^[a-f0-9]{64}$'),
    approved_by_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (id, workspace_id),
    CHECK (NOT enabled OR revoked_at IS NULL)
);

ALTER TABLE voice_call ALTER COLUMN actor_user_id DROP NOT NULL;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS direction TEXT NOT NULL DEFAULT 'outbound';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'outbound_request';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_principal TEXT NOT NULL DEFAULT 'workspace_user';
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_grant_id UUID;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS execution_grant_version BIGINT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS grant_capabilities JSONB;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS runtime_before TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_hash TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS adoption_receipt JSONB;
ALTER TABLE voice_business_result ALTER COLUMN actor_user_id DROP NOT NULL;
ALTER TABLE voice_business_result ADD COLUMN IF NOT EXISTS execution_grant_id UUID;
ALTER TABLE voice_business_result ADD COLUMN IF NOT EXISTS execution_grant_version BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_execution_scope') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_execution_scope CHECK (
            (direction='outbound' AND origin='outbound_request' AND execution_principal='workspace_user'
                AND actor_user_id IS NOT NULL AND execution_grant_id IS NULL AND execution_grant_version IS NULL
                AND grant_capabilities IS NULL AND runtime_before IS NULL AND adoption_receipt IS NULL)
            OR (direction='inbound' AND origin='carrier_inbound' AND execution_principal='workspace_service_grant'
                AND actor_user_id IS NULL AND execution_grant_id IS NOT NULL AND execution_grant_version IS NOT NULL AND execution_grant_version > 0
                AND grant_capabilities IS NOT NULL AND jsonb_typeof(grant_capabilities)='array' AND runtime_before IS NOT NULL
                AND start_before IS NULL AND connect_before IS NOT NULL AND runtime_before >= connect_before
                AND NOT dispatch_attempted AND NOT suppression_pending AND encrypted_destination IS NULL
                AND nonce_hash IS NOT NULL AND nonce_hash ~ '^[a-f0-9]{64}$' AND adoption_receipt IS NOT NULL)
        );
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_execution_grant_scope FOREIGN KEY (execution_grant_id,workspace_id)
            REFERENCES voice_service_grant(id,workspace_id) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_business_result'::regclass AND conname='voice_business_result_execution_scope') THEN
        ALTER TABLE voice_business_result ADD CONSTRAINT voice_business_result_execution_scope CHECK (
            (actor_user_id IS NOT NULL AND execution_grant_id IS NULL AND execution_grant_version IS NULL)
            OR (actor_user_id IS NULL AND execution_grant_id IS NOT NULL AND execution_grant_version IS NOT NULL AND execution_grant_version > 0)
        );
        ALTER TABLE voice_business_result ADD CONSTRAINT voice_business_result_execution_grant_scope FOREIGN KEY (execution_grant_id,workspace_id)
            REFERENCES voice_service_grant(id,workspace_id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS voice_call_nonce_once ON voice_call(nonce_hash) WHERE nonce_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_inbound_provider_once
    ON voice_call((auth_snapshot->>'provider_account_sid'),provider_call_sid) WHERE direction='inbound';

-- Parsed, authenticated metadata only; early terminal evidence cannot be revived by adoption.
CREATE TABLE IF NOT EXISTS voice_inbound_event (
    event_id UUID PRIMARY KEY,
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    binding_id UUID NOT NULL,
    body_hash TEXT NOT NULL CHECK (body_hash ~ '^[a-f0-9]{64}$'),
    event JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_inbound_event_call ON voice_inbound_event(call_id,workspace_id);

CREATE OR REPLACE FUNCTION voice_inbound_snapshot_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.direction IS DISTINCT FROM OLD.direction OR NEW.origin IS DISTINCT FROM OLD.origin
        OR NEW.execution_principal IS DISTINCT FROM OLD.execution_principal
        OR NEW.actor_user_id IS DISTINCT FROM OLD.actor_user_id
        OR NEW.execution_grant_id IS DISTINCT FROM OLD.execution_grant_id
        OR NEW.execution_grant_version IS DISTINCT FROM OLD.execution_grant_version
        OR NEW.grant_capabilities IS DISTINCT FROM OLD.grant_capabilities
        OR (OLD.direction='inbound' AND (
            NEW.request_hash IS DISTINCT FROM OLD.request_hash OR NEW.request_id IS DISTINCT FROM OLD.request_id
            OR NEW.workspace_id IS DISTINCT FROM OLD.workspace_id OR NEW.binding_id IS DISTINCT FROM OLD.binding_id
            OR NEW.configuration_version IS DISTINCT FROM OLD.configuration_version
            OR NEW.profile_ref IS DISTINCT FROM OLD.profile_ref OR NEW.profile_version IS DISTINCT FROM OLD.profile_version
            OR NEW.settings_version IS DISTINCT FROM OLD.settings_version OR NEW.max_duration_seconds IS DISTINCT FROM OLD.max_duration_seconds
            OR NEW.start_before IS DISTINCT FROM OLD.start_before OR NEW.connect_before IS DISTINCT FROM OLD.connect_before
            OR NEW.runtime_before IS DISTINCT FROM OLD.runtime_before OR NEW.nonce_hash IS DISTINCT FROM OLD.nonce_hash
            OR NEW.adoption_receipt IS DISTINCT FROM OLD.adoption_receipt OR NEW.provider_call_sid IS DISTINCT FROM OLD.provider_call_sid
        )) THEN
        RAISE EXCEPTION 'Voice execution scope and incoming receipt are immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_inbound_snapshot_immutable ON voice_call;
CREATE TRIGGER voice_inbound_snapshot_immutable BEFORE UPDATE ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_inbound_snapshot_immutable();
