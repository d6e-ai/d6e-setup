-- Telnyx `call.hangup` carries the SIP hangup cause (e.g. "400"). Keep it per leg next to the generic
-- hangup_cause / hangup_source. Strictly additive and idempotent.
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS callee_sip_hangup_cause TEXT CHECK (char_length(callee_sip_hangup_cause) <= 64);
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_sip_hangup_cause TEXT CHECK (char_length(openai_sip_hangup_cause) <= 64);
