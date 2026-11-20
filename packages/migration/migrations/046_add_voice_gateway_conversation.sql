-- Nullable fields preserve previously approved fixed-fallback settings and calls.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS gateway_model TEXT;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS agent_instructions TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS gateway_model TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS agent_instructions TEXT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_workspace_setting'::regclass AND conname='voice_workspace_gateway_config') THEN
        ALTER TABLE voice_workspace_setting ADD CONSTRAINT voice_workspace_gateway_config CHECK (
            (profile_ref <> 'gateway-conversation-v1' AND gateway_model IS NULL AND agent_instructions IS NULL)
            OR (profile_ref = 'gateway-conversation-v1'
                AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
                AND gateway_model !~ '[[:space:][:cntrl:]]'
                AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
                AND position('://' in gateway_model)=0
                AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
                AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        );
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_gateway_config') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_gateway_config CHECK (
            (profile_ref <> 'gateway-conversation-v1' AND gateway_model IS NULL AND agent_instructions IS NULL)
            OR (profile_ref = 'gateway-conversation-v1'
                AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
                AND gateway_model !~ '[[:space:][:cntrl:]]'
                AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
                AND position('://' in gateway_model)=0
                AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
                AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        );
    END IF;
END $$;

CREATE OR REPLACE FUNCTION voice_call_gateway_snapshot_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.gateway_model IS DISTINCT FROM OLD.gateway_model
        OR NEW.agent_instructions IS DISTINCT FROM OLD.agent_instructions THEN
        RAISE EXCEPTION 'Voice call configuration is immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_call_gateway_snapshot_immutable ON voice_call;
CREATE TRIGGER voice_call_gateway_snapshot_immutable BEFORE UPDATE ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_call_gateway_snapshot_immutable();
