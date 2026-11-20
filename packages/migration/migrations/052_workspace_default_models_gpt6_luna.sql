-- Migration: Move the system default models to the 2026-10 lineup.
-- GPT-5.6 Luna and Claude Haiku 4.5 are now hidden legacy models, so the
-- workspace chat / SNS default becomes openai / gpt-6-luna and the
-- per-user verification default becomes claude-haiku-5-5. Only rows still on
-- the previous system default are migrated; custom choices are untouched.
-- Idempotent: re-running only resets the column defaults to the same values.

ALTER TABLE frontend.workspace_default_models
    ALTER COLUMN chat_provider SET DEFAULT 'openai',
    ALTER COLUMN chat_model SET DEFAULT 'gpt-6-luna',
    ALTER COLUMN sns_provider SET DEFAULT 'openai',
    ALTER COLUMN sns_model SET DEFAULT 'gpt-6-luna';

UPDATE frontend.workspace_default_models
SET chat_model = 'gpt-6-luna',
    updated_at = NOW()
WHERE chat_provider = 'openai'
  AND chat_model = 'gpt-5.6-luna';

UPDATE frontend.workspace_default_models
SET sns_model = 'gpt-6-luna',
    updated_at = NOW()
WHERE sns_provider = 'openai'
  AND sns_model = 'gpt-5.6-luna';

ALTER TABLE frontend.user_workspace_settings
    ALTER COLUMN verification_model SET DEFAULT 'claude-haiku-5-5';

UPDATE frontend.user_workspace_settings
SET verification_model = 'claude-haiku-5-5',
    updated_at = NOW()
WHERE verification_provider = 'anthropic'
  AND verification_model = 'claude-haiku-4-5';
