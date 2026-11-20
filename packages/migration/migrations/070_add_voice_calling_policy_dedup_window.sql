-- How long after a live call was placed another one to the same number or lead is refused as a
-- duplicate. 0 turns the period check off; a call still starting or in progress is refused
-- regardless.
ALTER TABLE voice_calling_policy
    ADD COLUMN IF NOT EXISTS dedup_window_minutes INTEGER NOT NULL DEFAULT 30
        CHECK (dedup_window_minutes BETWEEN 0 AND 1440);
