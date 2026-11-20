-- A process that has not been restarted still inserts voice_delegation without
-- operation_id. Fill `{live_session_id}:{delegation_id}` so that insert keeps
-- the same business id the new handler writes. A supplied id is left as it is.

CREATE OR REPLACE FUNCTION voice_delegation_set_operation_id() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.operation_id IS NULL OR length(btrim(NEW.operation_id)) = 0 THEN
        NEW.operation_id := NEW.live_session_id::text || ':' || NEW.delegation_id;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS voice_delegation_set_operation_id ON voice_delegation;
CREATE TRIGGER voice_delegation_set_operation_id BEFORE INSERT ON voice_delegation
FOR EACH ROW EXECUTE FUNCTION voice_delegation_set_operation_id();
