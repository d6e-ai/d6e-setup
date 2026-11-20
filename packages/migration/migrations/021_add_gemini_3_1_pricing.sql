-- Migration: Correct Gemini 3.x pricing and register 3.1 Pro / Flash-Lite.
--
-- This migration does two things:
--   1. Adds Gemini 3.1 Pro and 3.1 Flash-Lite preview entries to
--      frontend.model_pricing so credit-based billing is ready when those
--      models are enabled in the UI.
--   2. Corrects the Gemini 3 Pro and 3 Flash-Preview rows inserted by
--      migration 014, which accidentally used the Gemini 2.5 Pro / 2.5 Flash
--      rates ($1.25/$10.00 and $0.15/$0.60). The actual Gemini 3 rates are
--      $2.00/$12.00 (Pro) and $0.50/$3.00 (Flash).
--
-- Notes:
-- - Pricing is in USD per million tokens (MTok), consistent with migration 014.
-- - ON CONFLICT (provider, model_pattern) DO UPDATE makes this migration
--   idempotent and also applies the 3.0 price correction in a single pass.
-- - Gemini 3 Pro and 3.1 Pro currently share the same base-tier rate
--   upstream; if they diverge, update the pair together.
-- - Upstream publishes a tiered input rate for >200K tokens (Gemini 3 Pro /
--   3.1 Pro). The credit system reads a single flat rate today, so the base
--   tier is used. Revisit alongside the tiered lookup work.
-- - The "-preview" suffix matches the current provider model IDs; rename
--   when Google graduates these models to GA.
-- - The model-selector UI keeps the Gemini rows commented out until
--   large-schema MCP tool-calling reliability improves, so these rows are
--   preparatory and not exercised for billing yet.

INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    ('google', 'gemini-3.1-pro-preview',        2.00, 12.00),
    ('google', 'gemini-3.1-flash-lite-preview', 0.25,  1.50),
    ('google', 'gemini-3-pro-preview',          2.00, 12.00),
    ('google', 'gemini-3-flash-preview',        0.50,  3.00)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();
