-- Migration: Add claude-opus-4-7 pricing to frontend.model_pricing.
--
-- Registers Anthropic's Claude Opus 4.7 (and its Extended Thinking variant) so
-- that credit-based billing calculates costs correctly for requests using the
-- new model. Pricing matches Claude Opus 4.6 as defined in seed.sql and the
-- model-selector component.
--
-- Notes:
-- - Pricing is in USD per million tokens (MTok), consistent with migration 014.
-- - ON CONFLICT (provider, model_pattern) DO UPDATE keeps the migration
--   idempotent and allows price updates on re-run.
-- - The "-thinking" suffix variant is not inserted separately because the
--   model_pricing lookup uses the base model pattern; add it only if pricing
--   ever diverges from the base Opus 4.7 model.

INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    ('anthropic', 'claude-opus-4-7', 5.00, 25.00)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();
