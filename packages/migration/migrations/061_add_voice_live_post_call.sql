-- Durable post-call processing and the call outcome of a GPT-Live session. Additive; idempotent.
--
-- post_call_*: the post-call job of a session that ended (closed or lost), queued by the same UPDATE that
-- makes the session terminal and run by the live poller with its own lease (lease_owner / lease_expires_at
-- must stay NULL on a terminal session, see 057). NULL post_call_state: no job (a live session, a failed one,
-- or a session that ended before this migration; old calls are never re-run).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_state TEXT
    CHECK (post_call_state IN ('pending', 'running', 'done', 'failed'));
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_attempts INTEGER NOT NULL DEFAULT 0
    CHECK (post_call_attempts >= 0);
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_next_at TIMESTAMPTZ;
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_lease_expires_at TIMESTAMPTZ;
-- A short machine-readable code of the last failure, never an error message.
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS post_call_error TEXT
    CHECK (char_length(post_call_error) <= 64);
-- The CRM lead an inbound caller's number matched, sealed like the transcript (VoiceKeys::seal_live_secret,
-- field "lead_key:<session id>"). The post-call job may run on another replica than the one that took the call.
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS lead_key_enc TEXT
    CHECK (char_length(lead_key_enc) <= 2048);
-- The job query: jobs that are waiting or whose runner died.
CREATE INDEX IF NOT EXISTS voice_live_session_post_call ON voice_live_session(post_call_next_at, created_at)
    WHERE post_call_state IN ('pending', 'running');

-- A follow-up item: a call a person must act on (urgent or needs_review output, a caller no CRM lead matches,
-- a CRM write that did not happen, no post_call workflow, a lost sideband, or a post-call job that failed).
ALTER TABLE voice_live_review DROP CONSTRAINT IF EXISTS voice_live_review_kind_check;
ALTER TABLE voice_live_review ADD CONSTRAINT voice_live_review_kind_check
    CHECK (kind IN ('dnc_request', 'opt_out', 'disallowed_op', 'screened_output', 'follow_up'));

-- What the post_call workflow made of a call, kept independent of the CRM so a caller who matches no lead
-- is not lost. summary and next_action are AES-256-GCM ciphertext (VoiceKeys::seal_live_secret, fields
-- "outcome_summary:<session id>" and "outcome_next_action:<session id>"), never plaintext. status is a
-- short code. Purged with the transcript (voice::live::worker::purge_expired_call_data).
CREATE TABLE IF NOT EXISTS voice_live_call_outcome (
    live_session_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    encrypted_summary TEXT CHECK (char_length(encrypted_summary) BETWEEN 1 AND 16384),
    encrypted_next_action TEXT CHECK (char_length(encrypted_next_action) BETWEEN 1 AND 16384),
    status TEXT CHECK (char_length(status) <= 64),
    callback_at TIMESTAMPTZ,
    needs_follow_up BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS voice_live_call_outcome_workspace
    ON voice_live_call_outcome(workspace_id, created_at);
