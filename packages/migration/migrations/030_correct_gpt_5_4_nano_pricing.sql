-- Migration: Correct gpt-5.4-nano pricing to match OpenAI's official rates.
--
-- Background:
--   Migration 014 (and seed.sql) inserted `gpt-5.4-nano` at $0.10 / $0.40
--   per million tokens. The actual upstream rate published by OpenAI is
--   $0.20 input / $1.25 output per Mtok (see
--   https://developers.openai.com/api/docs/pricing — confirmed 2026-05).
--   The legacy values appear to have been copied from `gpt-4.1-nano`
--   ($0.10 / $0.40), which is a different model family.
--
--   With the incorrect rates, every gpt-5.4-nano request was billed at
--   roughly half the input cost and one-third of the output cost,
--   under-charging the AI credit ledger.
--
-- Operations:
--   1. Update the existing `gpt-5.4-nano` row in frontend.model_pricing to
--      the correct base rates. Future requests will compute
--      estimated_cost_usd (and therefore AI credits) correctly.
--
-- Notes:
--   - Pricing is in USD per million tokens (MTok), consistent with
--     migrations 014 / 020 / 021 / 028 / 029.
--   - ON CONFLICT (provider, model_pattern) DO UPDATE keeps this migration
--     idempotent and lets it serve as a price update if rates drift again.
--   - Historical llm_usage rows (`estimated_cost_usd`) are intentionally
--     left untouched. They reflect the price at the time of the request
--     and are not rewritten retroactively, mirroring how migration 021
--     corrected the Gemini 3 rates.

INSERT INTO frontend.model_pricing
    (provider, model_pattern, input_price_per_mtok, output_price_per_mtok)
VALUES
    ('openai', 'gpt-5.4-nano', 0.20, 1.25)
ON CONFLICT (provider, model_pattern) DO UPDATE SET
    input_price_per_mtok  = EXCLUDED.input_price_per_mtok,
    output_price_per_mtok = EXCLUDED.output_price_per_mtok,
    updated_at            = NOW();
