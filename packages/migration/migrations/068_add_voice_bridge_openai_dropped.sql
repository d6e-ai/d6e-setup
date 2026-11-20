-- Outbound pre-dial v2: OpenAI dropped the pending incoming leg before it was accepted (while the callee
-- still rang). The row remembers it, so the callee's answer converts the call to the classic flow
-- (OpenAI dialed after the answer). Strictly additive and idempotent.
ALTER TABLE voice_live_bridge_call ADD COLUMN IF NOT EXISTS openai_dropped_at TIMESTAMPTZ;
