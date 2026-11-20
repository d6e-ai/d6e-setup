-- Migration: Normalize legacy Claude model ids and add GPT-5.5 pricing.
--
-- Context:
--   The frontend model selector previously exposed Anthropic models with an
--   explicit `-thinking` suffix and `claude-sonnet-4-5`. Both have been
--   retired: Claude 4.6+ models now use Anthropic's native adaptive
--   thinking (configured via providerOptions.anthropic.thinking.adaptive),
--   and `claude-sonnet-4-5` was superseded by `claude-sonnet-4-6`.
--
--   This migration brings persisted server-side settings in line with the
--   new selector so existing workspaces don't end up with model ids the
--   selector no longer offers (which would otherwise cause the selector
--   fallback to fire and surprise admins).
--
-- Operations:
--   1. Normalize `frontend.workspace_default_models.chat_model` and
--      `sns_model` by stripping `-thinking` suffixes and rewriting any
--      `claude-sonnet-4-5*` value to `claude-sonnet-4-6`.
--   2. Apply the same normalization to
--      `frontend.user_workspace_settings.verification_model`, which is also
--      driven from a `ModelSelector` instance in the workspace settings UI.
--   3. Retire the `claude-sonnet-4-5` row in `frontend.model_pricing`.
--      Pricing rows are a backend-only lookup; removing the unreachable
--      row keeps the table aligned with the model catalogue. Migration 014
--      still inserts this row on a brand-new database, so we explicitly
--      delete it here on upgrade paths.
--   4. Add the `gpt-5.5` pricing row. Rates mirror seed.sql.
--
-- Notes:
--   - Each UPDATE is wrapped in its own `WHERE` clause so the migration is
--     idempotent: re-running it after a clean upgrade is a no-op because
--     the rows already store the canonical ids.
--   - The `claude-sonnet-4-5-thinking` variant is rewritten to
--     `claude-sonnet-4-6` (not `claude-sonnet-4-5`) because Sonnet 4.5
--     itself is retired.

-- 1. workspace_default_models: chat_model normalization.
UPDATE frontend.workspace_default_models
SET chat_model = 'claude-opus-4-7',
    updated_at = NOW()
WHERE chat_model = 'claude-opus-4-7-thinking';

UPDATE frontend.workspace_default_models
SET chat_model = 'claude-opus-4-6',
    updated_at = NOW()
WHERE chat_model = 'claude-opus-4-6-thinking';

UPDATE frontend.workspace_default_models
SET chat_model = 'claude-sonnet-4-6',
    updated_at = NOW()
WHERE chat_model IN (
    'claude-sonnet-4-6-thinking',
    'claude-sonnet-4-5',
    'claude-sonnet-4-5-thinking'
);

-- 1b. workspace_default_models: sns_model normalization.
UPDATE frontend.workspace_default_models
SET sns_model = 'claude-opus-4-7',
    updated_at = NOW()
WHERE sns_model = 'claude-opus-4-7-thinking';

UPDATE frontend.workspace_default_models
SET sns_model = 'claude-opus-4-6',
    updated_at = NOW()
WHERE sns_model = 'claude-opus-4-6-thinking';

UPDATE frontend.workspace_default_models
SET sns_model = 'claude-sonnet-4-6',
    updated_at = NOW()
WHERE sns_model IN (
    'claude-sonnet-4-6-thinking',
    'claude-sonnet-4-5',
    'claude-sonnet-4-5-thinking'
);

-- 2. user_workspace_settings.verification_model: same normalization.
UPDATE frontend.user_workspace_settings
SET verification_model = 'claude-opus-4-7',
    updated_at = NOW()
WHERE verification_model = 'claude-opus-4-7-thinking';

UPDATE frontend.user_workspace_settings
SET verification_model = 'claude-opus-4-6',
    updated_at = NOW()
WHERE verification_model = 'claude-opus-4-6-thinking';

UPDATE frontend.user_workspace_settings
SET verification_model = 'claude-sonnet-4-6',
    updated_at = NOW()
WHERE verification_model IN (
    'claude-sonnet-4-6-thinking',
    'claude-sonnet-4-5',
    'claude-sonnet-4-5-thinking'
);

-- 3. Drop the retired pricing row.
DELETE FROM frontend.model_pricing
WHERE provider = 'anthropic'
  AND model_pattern = 'claude-sonnet-4-5';

-- 4. Add gpt-5.5 pricing (USD per million tokens).
INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    ('openai', 'gpt-5.5', 5.00, 30.00)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();
