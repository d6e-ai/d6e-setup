-- Purpose-limited application execution acceptance. No request bodies or credentials.
CREATE TABLE IF NOT EXISTS frontend.application_operation_nonce (
    application_id TEXT NOT NULL,
    instance_id UUID NOT NULL,
    request_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (application_id, instance_id, request_id)
);

CREATE INDEX IF NOT EXISTS application_operation_nonce_expiry_idx
    ON frontend.application_operation_nonce (expires_at);

CREATE TABLE IF NOT EXISTS frontend.application_execution_mutation (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    application_id TEXT NOT NULL,
    instance_id UUID NOT NULL,
    external_issuer TEXT NOT NULL,
    external_tenant_id UUID NOT NULL,
    external_actor_id UUID NOT NULL,
    service_actor_id UUID NOT NULL REFERENCES public."user"(id),
    workspace_id UUID NOT NULL REFERENCES public.workspace(id),
    operation TEXT NOT NULL CHECK (operation IN ('execution.launch', 'execution.cancel')),
    registration_revision TEXT NOT NULL,
    runtime_profile TEXT NOT NULL,
    idempotency_key_digest TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    execution_id UUID REFERENCES frontend.ephemeral_execution(id),
    attempt_id UUID,
    attempt_expires_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT application_execution_mutation_identity_unique
        UNIQUE (application_id, instance_id, external_tenant_id, external_actor_id, idempotency_key_digest),
    CONSTRAINT application_execution_mutation_attempt_consistent
        CHECK ((attempt_id IS NULL) = (attempt_expires_at IS NULL))
);

CREATE INDEX IF NOT EXISTS application_execution_mutation_execution_idx
    ON frontend.application_execution_mutation (execution_id)
    WHERE operation = 'execution.launch';
