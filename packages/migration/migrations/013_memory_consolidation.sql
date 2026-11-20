-- Memory consolidation improvement: adds version tracking and configurable per-user limit.
-- Truncates existing memories for a clean start with the new schema.

TRUNCATE frontend.user_memory;

ALTER TABLE frontend.user_memory
    ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;

ALTER TABLE frontend.user_workspace_settings
    ADD COLUMN IF NOT EXISTS memory_limit INTEGER NOT NULL DEFAULT 100;
