-- Migration: Add Gemini 3.1 Flash-Lite pricing under the graduated model ID.
--
-- Background:
--   Migration 021 registered the Gemini 3.1 Flash-Lite pricing row using the
--   upstream preview model ID 'gemini-3.1-flash-lite-preview'. The frontend
--   (see packages/frontend/src/lib/server/ai-providers.ts and seed.sql) now
--   references the graduated identifier 'gemini-3.1-flash-lite', so the
--   credit lookup misses on databases upgraded from migration 021. This
--   migration registers the canonical row so pricing resolves correctly.
--
-- Notes:
--   - The obsolete 'gemini-3.1-flash-lite-preview' row is intentionally
--     left in place. model_pricing is a backend-only lookup table (never
--     surfaced in the UI) and getModelPricing() in model-pricing.ts resolves
--     models by exact match on model_pattern, so the stale row is unreachable
--     from runtime and preserves the historical record.
--   - Pricing values mirror seed.sql / migration 021 (USD per million tokens).
--   - ON CONFLICT (provider, model_pattern) DO UPDATE keeps this migration
--     idempotent and also refreshes pricing if it ever drifts upstream.

INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    ('google', 'gemini-3.1-flash-lite', 0.25, 1.50)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();
