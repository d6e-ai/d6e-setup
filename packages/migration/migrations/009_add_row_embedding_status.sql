-- Add status tracking columns to embedding_config for async row embedding jobs.
-- Adds status (pending/processing/completed/failed), error_message, and
-- job_started_at to support tokio::spawn background processing with stale detection.

ALTER TABLE embedding_config
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'completed',
    ADD COLUMN IF NOT EXISTS error_message TEXT,
    ADD COLUMN IF NOT EXISTS job_started_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_embedding_config_workspace_status
    ON embedding_config (workspace_id, status);
