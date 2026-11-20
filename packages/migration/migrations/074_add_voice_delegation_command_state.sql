-- Whether the conversation service saw the delegation reply acknowledged or rejected.
-- Existing rows stay `pending`. The handler writes `acknowledged` or `failed` from that service.

ALTER TABLE voice_delegation ADD COLUMN IF NOT EXISTS command_state TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE voice_delegation DROP CONSTRAINT IF EXISTS voice_delegation_command_state_check;
ALTER TABLE voice_delegation ADD CONSTRAINT voice_delegation_command_state_check
    CHECK (command_state IN ('pending', 'acknowledged', 'failed'));
