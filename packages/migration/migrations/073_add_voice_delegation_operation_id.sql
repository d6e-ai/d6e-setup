-- The business id of one delegation, `{live_session_id}:{delegation_id}`.
-- Existing rows are filled here. The handler writes the id the conversation service recorded
-- when a delegation finishes. Callers that insert a row must supply the same id.

ALTER TABLE voice_delegation ADD COLUMN IF NOT EXISTS operation_id TEXT;

UPDATE voice_delegation
SET operation_id = live_session_id::text || ':' || delegation_id
WHERE operation_id IS NULL;

ALTER TABLE voice_delegation ALTER COLUMN operation_id SET NOT NULL;

ALTER TABLE voice_delegation DROP CONSTRAINT IF EXISTS voice_delegation_operation_id_length;
ALTER TABLE voice_delegation ADD CONSTRAINT voice_delegation_operation_id_length
    CHECK (char_length(operation_id) BETWEEN 1 AND 320);
