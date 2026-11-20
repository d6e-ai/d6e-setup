-- Allow Telnyx as a second voice carrier next to Twilio.
-- Idempotent: the constraint is dropped by name if present, then recreated with both carriers.
-- Existing rows all hold 'twilio', so re-adding the CHECK validates without data changes.
ALTER TABLE voice_provider_connection DROP CONSTRAINT IF EXISTS voice_provider_connection_provider_check;
ALTER TABLE voice_provider_connection
    ADD CONSTRAINT voice_provider_connection_provider_check CHECK (provider IN ('twilio', 'telnyx'));
