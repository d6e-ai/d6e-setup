-- Processing tier for the GPT-Live delegation models. Existing rows stay on standard so a
-- deploy does not start billing the Fast premium by itself. The admin UI defaults a new
-- fast model to Fast; Ultrafast is only meaningful for the models that offer it.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS fast_service_tier TEXT NOT NULL DEFAULT 'standard'
    CHECK (fast_service_tier IN ('standard', 'fast', 'ultrafast'));
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS slow_service_tier TEXT NOT NULL DEFAULT 'standard'
    CHECK (slow_service_tier IN ('standard', 'fast', 'ultrafast'));
