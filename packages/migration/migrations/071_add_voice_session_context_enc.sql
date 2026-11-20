-- Sealed session context for a sideband that is not the process that registered the call.
-- Lite already stores this column. Full's API still passes context in memory; the column is
-- nullable so existing rows stay valid, and a separate sideband process (Lite's resident
-- `d6e-voice-sideband`) can open it after a claim.

ALTER TABLE voice_live_session
    ADD COLUMN IF NOT EXISTS session_context_enc TEXT
        CHECK (session_context_enc IS NULL OR char_length(session_context_enc) <= 65536);
