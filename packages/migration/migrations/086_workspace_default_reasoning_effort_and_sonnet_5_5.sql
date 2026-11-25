-- Migration: Give the workspace default models a reasoning effort, and make
-- Claude Sonnet 5.5 (anthropic / claude-sonnet-5-5) the default model of the
-- workspaces created from now on. Existing workspaces keep what they use.
--
-- - chat_reasoning_effort / sns_reasoning_effort: `auto`, `low`, `medium`,
--   `high`, `xhigh` or `max`, chosen with the model on the console's
--   workspace settings page. `auto` leaves it to d6e (high for the Claude
--   models that think adaptively in the chat, the model's own default for
--   OpenAI), as every call ran before; existing rows get it, so nothing they
--   send changes. An effort the model does not take is read as `auto` where
--   the call is made.
-- - The code's default (the smart model, `D6E_AI_SMART_MODEL`) becomes
--   anthropic / claude-sonnet-5-5, so a workspace without a row would move to
--   it. Each existing workspace without a row gets one with the previous
--   default written out (openai / gpt-6-luna, standard, auto). Saved rows are
--   untouched.
-- - The column defaults become anthropic / claude-sonnet-5-5, for rows
--   written without them.
-- Idempotent: re-running sets the same defaults and adds no row a workspace
-- already has.

ALTER TABLE frontend.workspace_default_models
    ADD COLUMN IF NOT EXISTS chat_reasoning_effort TEXT NOT NULL DEFAULT 'auto',
    ADD COLUMN IF NOT EXISTS sns_reasoning_effort TEXT NOT NULL DEFAULT 'auto';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'workspace_default_models_chat_reasoning_effort_check'
    ) THEN
        ALTER TABLE frontend.workspace_default_models
            ADD CONSTRAINT workspace_default_models_chat_reasoning_effort_check
            CHECK (chat_reasoning_effort IN ('auto', 'low', 'medium', 'high', 'xhigh', 'max'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'workspace_default_models_sns_reasoning_effort_check'
    ) THEN
        ALTER TABLE frontend.workspace_default_models
            ADD CONSTRAINT workspace_default_models_sns_reasoning_effort_check
            CHECK (sns_reasoning_effort IN ('auto', 'low', 'medium', 'high', 'xhigh', 'max'));
    END IF;
END $$;

INSERT INTO frontend.workspace_default_models (
    workspace_id,
    chat_provider, chat_model, chat_service_tier, chat_reasoning_effort,
    sns_provider, sns_model, sns_service_tier, sns_reasoning_effort
)
SELECT id,
       'openai', 'gpt-6-luna', 'standard', 'auto',
       'openai', 'gpt-6-luna', 'standard', 'auto'
FROM workspace
ON CONFLICT (workspace_id) DO NOTHING;

ALTER TABLE frontend.workspace_default_models
    ALTER COLUMN chat_provider SET DEFAULT 'anthropic',
    ALTER COLUMN chat_model SET DEFAULT 'claude-sonnet-5-5',
    ALTER COLUMN sns_provider SET DEFAULT 'anthropic',
    ALTER COLUMN sns_model SET DEFAULT 'claude-sonnet-5-5';
