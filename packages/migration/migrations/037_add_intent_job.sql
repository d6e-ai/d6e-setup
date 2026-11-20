-- Migration: Async intent job table for execute-by-intent background runs.
--
-- Overview:
-- The existing /api/workflows/execute-by-intent endpoint runs the whole agent
-- loop synchronously: the caller holds one HTTP request open until completion.
-- Specialized frontends on Vercel (d6e-valuation) must fit inside their own
-- function budget (~800s maxDuration), so heavy runs fail with timeout.
--
-- This table backs a new async API:
--   POST /api/workflows/execute-by-intent/jobs   -> insert row, return jobId
--   GET  /api/workflows/execute-by-intent/jobs/{id} -> poll status + result
--   POST /api/workflows/execute-by-intent/jobs/{id}/cancel -> request cancel
--
-- The d6e frontend is a long-lived adapter-node process, so the agent run is
-- detached from the HTTP request lifetime and can exceed 13 minutes. Guardrails
-- (step cap, wall-clock cap, heartbeat) prevent runaway runs.
--
-- Constraints:
-- - One row per job; id is a UUIDv7 (time-ordered).
-- - status enum: queued -> running -> succeeded | failed | cancelled.
-- - heartbeat_at is touched periodically by the runner; a stale heartbeat
--   indicates the process died mid-run (the next GET finalizes as failed).
-- - cancel_requested lets a polling GET or another instance propagate the
--   cancellation signal to the runner's AbortController.
-- - tool_trace stores a capped array of { tool, startedAt, finishedAt } for
--   progress visibility; result stores the final IntentResponse JSON.

CREATE TYPE frontend.intent_job_status AS ENUM (
    'queued',
    'running',
    'succeeded',
    'failed',
    'cancelled'
);

CREATE TABLE IF NOT EXISTS frontend.intent_job (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,

    -- Request payload (message + optional file refs, same as sync endpoint body).
    request_payload JSONB NOT NULL,

    status frontend.intent_job_status NOT NULL DEFAULT 'queued',

    -- Runner heartbeat: touched every ~10s while running. A running row whose
    -- heartbeat is older than HEARTBEAT_STALE_MS is assumed dead (process crash /
    -- restart) and finalized as failed by the next reader.
    heartbeat_at TIMESTAMPTZ,

    -- Cooperative cancellation flag. The runner checks this on each heartbeat
    -- tick and aborts if true.
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,

    -- Wall-clock start/end for elapsed-time display and timeout enforcement.
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,

    -- Capped tool-call trace for progress display (array of objects).
    tool_trace JSONB NOT NULL DEFAULT '[]'::jsonb,

    -- Final result (IntentResponse JSON) or error message.
    result JSONB,
    error_message TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for listing a user's jobs in a workspace (most recent first).
CREATE INDEX IF NOT EXISTS idx_intent_job_workspace_user
    ON frontend.intent_job(workspace_id, user_id, created_at DESC);

-- Index for finding running jobs (heartbeat staleness check, per-workspace cap).
CREATE INDEX IF NOT EXISTS idx_intent_job_running
    ON frontend.intent_job(workspace_id, status) WHERE status = 'running';
