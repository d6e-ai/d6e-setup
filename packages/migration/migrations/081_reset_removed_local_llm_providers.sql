-- Ollama and LM Studio support was removed from the web app and the API.
-- Reset saved choices that still name them to the column defaults, so the
-- provider and its model change together (the readers would otherwise swap
-- only the provider and keep a local model id). Data only; no schema change.

UPDATE frontend.workspace_default_models
SET chat_provider = 'openai',
    chat_model = 'gpt-6-luna',
    chat_service_tier = 'standard',
    updated_at = NOW()
WHERE chat_provider IN ('ollama', 'lmstudio');

UPDATE frontend.workspace_default_models
SET sns_provider = 'openai',
    sns_model = 'gpt-6-luna',
    sns_service_tier = 'standard',
    updated_at = NOW()
WHERE sns_provider IN ('ollama', 'lmstudio');

UPDATE frontend.user_workspace_settings
SET verification_provider = 'anthropic',
    verification_model = 'claude-haiku-5-5',
    updated_at = NOW()
WHERE verification_provider IN ('ollama', 'lmstudio');
