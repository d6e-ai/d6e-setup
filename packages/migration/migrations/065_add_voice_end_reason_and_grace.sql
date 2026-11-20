-- Grace period after the inbound maximum call length, and the reason an auto-hangup ended a live
-- session. After the limit the call waits up to the grace period for a natural break before the
-- agent apologises and the call is cut; the reason lets the post-call job tell the two apart.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS max_duration_grace_seconds INTEGER NOT NULL DEFAULT 60
    CHECK (max_duration_grace_seconds BETWEEN 0 AND 300);
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS end_reason TEXT;
