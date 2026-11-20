-- Outbound pre-dial: the OpenAI SIP leg is dialed (and accepted) while the callee still rings, and the two
-- legs are bridged explicitly once both are ready. Strictly additive and idempotent; a row without
-- `predial` follows the old flow, so a deploy and a rollback change nothing for rows already in flight.
--   predial            the row was started in pre-dial mode (decided once, at start)
--   openai_accepted_at the OpenAI leg was accepted (early, with a silent hold) and its session registered
--   openai_answered_at Telnyx reported the OpenAI leg answered (call.answered of that leg)
--   bridge_attempts    explicit bridge attempts made (a not-ready answer releases the claim, bounded)
--   bridge_done_at     Telnyx accepted the explicit bridge (kept apart from the state move, so a lost
--                      `bridged` update can be repaired by the sweeper without killing the live call)
--   bridge_attempt_at  when the last explicit bridge attempt was claimed (attempts are spaced by a backoff)
--   bridge_claimed_at  the one explicit Telnyx bridge of this row was claimed (callee answered AND
--                      OpenAI accepted, whichever came second)
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS predial BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_accepted_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_claimed_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_answered_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_done_at TIMESTAMPTZ;
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS bridge_attempt_at TIMESTAMPTZ;
