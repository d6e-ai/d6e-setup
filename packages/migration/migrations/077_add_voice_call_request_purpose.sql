-- Optional purpose of an outbound call request (written by whoever asked for the call, a Bot's AI for
-- example). It is encrypted by the API (AES-GCM bound to the workspace, `p1:` prefix), shown in full to
-- the admin who approves the call, and used only for that call. `purpose_hash` (HMAC) lets an idempotent
-- repeat be compared without decrypting. The text the approver saw is the text that is used: after the
-- row is created the two columns can only be cleared together (retention), never changed.
ALTER TABLE voice_live_call_request ADD COLUMN IF NOT EXISTS encrypted_purpose TEXT;
ALTER TABLE voice_live_call_request ADD COLUMN IF NOT EXISTS purpose_hash TEXT;

ALTER TABLE voice_live_call_request DROP CONSTRAINT IF EXISTS voice_live_call_request_purpose_check;
ALTER TABLE voice_live_call_request ADD CONSTRAINT voice_live_call_request_purpose_check CHECK (
    (encrypted_purpose IS NULL AND purpose_hash IS NULL)
    OR (
        encrypted_purpose LIKE 'p1:%'
        AND char_length(encrypted_purpose) BETWEEN 4 AND 4096
        AND purpose_hash ~ '^[a-f0-9]{64}$'
    )
);

CREATE OR REPLACE FUNCTION voice_live_call_request_purpose_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.encrypted_purpose IS DISTINCT FROM OLD.encrypted_purpose
        OR NEW.purpose_hash IS DISTINCT FROM OLD.purpose_hash)
       AND NOT (NEW.encrypted_purpose IS NULL AND NEW.purpose_hash IS NULL) THEN
        RAISE EXCEPTION 'voice_live_call_request purpose cannot be changed after creation'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS voice_live_call_request_purpose_guard ON voice_live_call_request;
CREATE TRIGGER voice_live_call_request_purpose_guard
    BEFORE UPDATE OF encrypted_purpose, purpose_hash ON voice_live_call_request
    FOR EACH ROW EXECUTE FUNCTION voice_live_call_request_purpose_guard();
