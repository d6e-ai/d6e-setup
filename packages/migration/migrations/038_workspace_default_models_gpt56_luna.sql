-- Migration: Retire claude-sonnet-4-6 as the system default for workspace
-- default models. Existing workspaces that still have the previous seeded
-- anthropic / claude-sonnet-4-6 pair are migrated to openai / gpt-5.6-luna.
-- Custom workspace choices are left untouched.

ALTER TABLE frontend.workspace_default_models
    ALTER COLUMN chat_provider SET DEFAULT 'openai',
    ALTER COLUMN chat_model SET DEFAULT 'gpt-5.6-luna',
    ALTER COLUMN sns_provider SET DEFAULT 'openai',
    ALTER COLUMN sns_model SET DEFAULT 'gpt-5.6-luna';

UPDATE frontend.workspace_default_models
SET chat_provider = 'openai',
    chat_model = 'gpt-5.6-luna',
    updated_at = NOW()
WHERE chat_provider = 'anthropic'
  AND chat_model = 'claude-sonnet-4-6';

UPDATE frontend.workspace_default_models
SET sns_provider = 'openai',
    sns_model = 'gpt-5.6-luna',
    updated_at = NOW()
WHERE sns_provider = 'anthropic'
  AND sns_model = 'claude-sonnet-4-6';
