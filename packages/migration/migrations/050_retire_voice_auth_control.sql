-- Retire objects that only the d6e-auth control path used (see the 2026-10-20 BYO telephony ADR).
-- OPERATORS: take a full `pg_dump` of the instance database before applying this migration, and
-- check `SELECT count(*) FROM voice_envelope_replay` first. Dropped data cannot be recovered.
-- Apply only after the BYO call path is deployed and verified; it must stay a separate step from 049.
-- Apply with `psql -v ON_ERROR_STOP=1 -f 050_retire_voice_auth_control.sql`.
-- Guard: refuse to run while the auth path can still be in use, i.e. an unexpired relay replay
-- row exists or a call placed through the auth path (provider IS NULL) is not finished.
-- Every change runs inside this single DO block, so a refusal aborts all of it even when the
-- client keeps going after an error (psql without ON_ERROR_STOP): nothing is dropped.
-- Idempotent: once the replay table is gone only the call check remains.
DO $$
DECLARE
    pending BOOLEAN;
BEGIN
    IF to_regclass('public.voice_envelope_replay') IS NOT NULL THEN
        EXECUTE 'SELECT EXISTS (SELECT 1 FROM voice_envelope_replay WHERE expires_at > now())'
            INTO pending;
        IF pending THEN
            RAISE EXCEPTION '050 refused: voice_envelope_replay has unexpired rows; wait until they expire';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM voice_call
        WHERE provider IS NULL AND state NOT IN ('ended', 'canceled', 'failed')
    ) THEN
        RAISE EXCEPTION '050 refused: voice_call has unfinished calls placed through the auth path (provider IS NULL)';
    END IF;
    DROP TABLE IF EXISTS voice_envelope_replay;
    -- Replaced by voice_call_provider_call_once (049), which keys on provider and provider_account_ref.
    DROP INDEX IF EXISTS voice_call_inbound_provider_once;
    -- Auth binding identifiers no longer exist for service grants or carrier inbound events.
    ALTER TABLE voice_service_grant ALTER COLUMN binding_id DROP NOT NULL;
    ALTER TABLE voice_service_grant ALTER COLUMN configuration_version DROP NOT NULL;
    ALTER TABLE voice_inbound_event ALTER COLUMN binding_id DROP NOT NULL;
END $$;
