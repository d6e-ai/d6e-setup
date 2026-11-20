-- Migration: Add enabled flag to saas_credential.
-- When disabled, the SaaS proxy rejects API calls for this credential,
-- preventing unintended data access while keeping the credential stored.

ALTER TABLE frontend.saas_credential
    ADD COLUMN IF NOT EXISTS enabled BOOLEAN NOT NULL DEFAULT TRUE;
