-- Only bounded FDE result metadata and scoped execution UUIDs are retained.
CREATE UNIQUE INDEX IF NOT EXISTS voice_tool_execution_result_scope
    ON voice_tool_execution(call_id, workspace_id, execution_id, session_generation);

CREATE TABLE IF NOT EXISTS voice_business_result (
    call_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    result_id UUID NOT NULL UNIQUE CHECK (result_id <> '00000000-0000-0000-0000-000000000000'),
    state TEXT NOT NULL CHECK (state IN ('succeeded', 'failed', 'needs_review')),
    reason TEXT NOT NULL CHECK (reason IN (
        'verified_tool_applied', 'tool_no_action', 'policy_rejected',
        'recipient_declined', 'tool_uncertain', 'policy_review_required'
    )),
    request_hash TEXT NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'),
    evidence_count SMALLINT NOT NULL CHECK (evidence_count BETWEEN 0 AND 8),
    actor_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    profile_version TEXT NOT NULL CHECK (char_length(profile_version) BETWEEN 1 AND 128),
    session_owner UUID NOT NULL CHECK (session_owner <> '00000000-0000-0000-0000-000000000000'),
    session_generation BIGINT NOT NULL CHECK (session_generation > 0),
    turn_generation BIGINT NOT NULL CHECK (turn_generation >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (call_id, workspace_id, result_id, session_generation),
    CHECK (
        (state = 'succeeded' AND reason = 'verified_tool_applied' AND evidence_count > 0)
        OR (state = 'failed' AND (
            (reason = 'tool_no_action' AND evidence_count > 0)
            OR reason IN ('policy_rejected', 'recipient_declined')
        ))
        OR (state = 'needs_review' AND (
            (reason = 'tool_uncertain' AND evidence_count > 0)
            OR reason = 'policy_review_required'
        ))
    )
);
CREATE TABLE IF NOT EXISTS voice_business_result_evidence (
    call_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    result_id UUID NOT NULL,
    session_generation BIGINT NOT NULL,
    ordinal SMALLINT NOT NULL CHECK (ordinal BETWEEN 1 AND 8),
    execution_id UUID NOT NULL CHECK (execution_id <> '00000000-0000-0000-0000-000000000000'),
    PRIMARY KEY (call_id, execution_id),
    UNIQUE (call_id, ordinal),
    FOREIGN KEY (call_id, workspace_id, result_id, session_generation)
        REFERENCES voice_business_result(call_id, workspace_id, result_id, session_generation) ON DELETE RESTRICT,
    FOREIGN KEY (call_id, workspace_id, execution_id, session_generation)
        REFERENCES voice_tool_execution(call_id, workspace_id, execution_id, session_generation) ON DELETE RESTRICT
);

CREATE OR REPLACE FUNCTION voice_business_result_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Voice business results and evidence are immutable';
END $$;
DROP TRIGGER IF EXISTS voice_business_result_immutable ON voice_business_result;
CREATE TRIGGER voice_business_result_immutable BEFORE UPDATE OR DELETE ON voice_business_result
FOR EACH ROW EXECUTE FUNCTION voice_business_result_immutable();
DROP TRIGGER IF EXISTS voice_business_result_evidence_immutable ON voice_business_result_evidence;
CREATE TRIGGER voice_business_result_evidence_immutable BEFORE UPDATE OR DELETE ON voice_business_result_evidence
FOR EACH ROW EXECUTE FUNCTION voice_business_result_immutable();

-- Deferred completeness makes the bounded link set immutable after the transaction commits.
CREATE OR REPLACE FUNCTION voice_business_result_evidence_complete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    result_call UUID := NEW.call_id;
    expected_count SMALLINT;
    actual_count BIGINT;
BEGIN
    SELECT evidence_count INTO expected_count FROM voice_business_result WHERE call_id=result_call;
    SELECT count(*) INTO actual_count FROM voice_business_result_evidence WHERE call_id=result_call;
    IF expected_count IS NULL OR actual_count <> expected_count
        OR EXISTS (SELECT 1 FROM voice_business_result_evidence WHERE call_id=result_call AND ordinal > expected_count) THEN
        RAISE EXCEPTION 'Voice business result evidence must be complete and bounded';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_evidence_complete ON voice_business_result;
CREATE CONSTRAINT TRIGGER voice_business_result_evidence_complete
AFTER INSERT ON voice_business_result DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION voice_business_result_evidence_complete();
DROP TRIGGER IF EXISTS voice_business_result_evidence_complete ON voice_business_result_evidence;
CREATE CONSTRAINT TRIGGER voice_business_result_evidence_complete
AFTER INSERT ON voice_business_result_evidence DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION voice_business_result_evidence_complete();

CREATE OR REPLACE FUNCTION voice_business_result_projection_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    recorded_state TEXT;
BEGIN
    SELECT state INTO recorded_state FROM voice_business_result WHERE call_id=NEW.id AND workspace_id=NEW.workspace_id;
    IF NEW.business_state IS DISTINCT FROM COALESCE(recorded_state, 'incomplete') THEN
        RAISE EXCEPTION 'Voice business state must match its immutable FDE result';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_projection_guard ON voice_call;
CREATE TRIGGER voice_business_result_projection_guard BEFORE INSERT OR UPDATE OF business_state ON voice_call
FOR EACH ROW EXECUTE FUNCTION voice_business_result_projection_guard();

CREATE OR REPLACE FUNCTION voice_business_result_project() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE voice_call SET business_state=NEW.state,updated_at=now()
        WHERE id=NEW.call_id AND workspace_id=NEW.workspace_id;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_project ON voice_business_result;
CREATE TRIGGER voice_business_result_project AFTER INSERT ON voice_business_result
FOR EACH ROW EXECUTE FUNCTION voice_business_result_project();

-- Reconciliation may settle unknown evidence; an already completed receipt cannot be rewritten.
CREATE OR REPLACE FUNCTION voice_business_result_tool_receipt_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM voice_business_result_evidence WHERE call_id=OLD.call_id AND execution_id=OLD.execution_id)
        AND (NEW.capability IS DISTINCT FROM OLD.capability
            OR NEW.input_hash IS DISTINCT FROM OLD.input_hash
            OR (OLD.state = 'completed' AND (
                NEW.state IS DISTINCT FROM OLD.state OR NEW.result IS DISTINCT FROM OLD.result
            ))) THEN
        RAISE EXCEPTION 'Voice business result tool receipts are immutable';
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS voice_business_result_tool_receipt_guard ON voice_tool_execution;
CREATE TRIGGER voice_business_result_tool_receipt_guard BEFORE UPDATE ON voice_tool_execution
FOR EACH ROW EXECUTE FUNCTION voice_business_result_tool_receipt_guard();
