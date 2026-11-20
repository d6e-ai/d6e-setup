-- Workspace default models can opt into Fast or Ultrafast.
-- Existing rows stay standard so a deploy does not change what they are billed.
-- Fast is OpenAI Fast. Ultrafast is only meaningful for gpt-6.1-sol and gpt-6-astra;
-- the application drops Ultrafast for every other model.

ALTER TABLE frontend.workspace_default_models
    ADD COLUMN IF NOT EXISTS chat_service_tier TEXT NOT NULL DEFAULT 'standard',
    ADD COLUMN IF NOT EXISTS sns_service_tier TEXT NOT NULL DEFAULT 'standard';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'workspace_default_models_chat_service_tier_check'
    ) THEN
        ALTER TABLE frontend.workspace_default_models
            ADD CONSTRAINT workspace_default_models_chat_service_tier_check
            CHECK (chat_service_tier IN ('standard', 'fast', 'ultrafast'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'workspace_default_models_sns_service_tier_check'
    ) THEN
        ALTER TABLE frontend.workspace_default_models
            ADD CONSTRAINT workspace_default_models_sns_service_tier_check
            CHECK (sns_service_tier IN ('standard', 'fast', 'ultrafast'));
    END IF;
END $$;
