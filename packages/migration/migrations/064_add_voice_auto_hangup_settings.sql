-- Auto-hangup settings of the GPT-Live agent and a longer inbound call limit.
-- Auto-hangup is OFF for both directions so a deploy does not change how a call ends. The inbound
-- maximum call length is now enforced; the new default is 600 s and the range 30..1800 s. Existing
-- policy rows keep the value they have.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS auto_hangup_inbound BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS auto_hangup_outbound BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS idle_prompt_after_seconds INTEGER NOT NULL DEFAULT 15
    CHECK (idle_prompt_after_seconds BETWEEN 5 AND 60);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS idle_max_prompts INTEGER NOT NULL DEFAULT 2
    CHECK (idle_max_prompts BETWEEN 1 AND 5);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS closing_grace_seconds INTEGER NOT NULL DEFAULT 6
    CHECK (closing_grace_seconds BETWEEN 3 AND 15);

ALTER TABLE voice_inbound_policy ALTER COLUMN max_duration_seconds SET DEFAULT 600;
ALTER TABLE voice_inbound_policy DROP CONSTRAINT IF EXISTS voice_inbound_policy_max_duration_seconds_check;
ALTER TABLE voice_inbound_policy ADD CONSTRAINT voice_inbound_policy_max_duration_seconds_check
    CHECK (max_duration_seconds BETWEEN 30 AND 1800);
