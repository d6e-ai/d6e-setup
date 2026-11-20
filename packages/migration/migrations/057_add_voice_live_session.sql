-- GPT-Live sideband sessions. Strictly additive: new tables and indexes only.
-- One row per OpenAI Live session that d6e attaches a sideband WebSocket to, plus its transcript.
-- Retained audit data must not disappear with a workspace, hence ON DELETE RESTRICT (as in 056).

-- A live session and the lease that makes exactly one API replica own its sideband attach.
-- Timeline of status: created -> ringing -> answered -> closed; failed (transport.failed) and
-- lost (sideband could not be re-attached, final usage unconfirmed) are terminal as well.
CREATE TABLE IF NOT EXISTS voice_live_session (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    voice_call_id UUID,
    openai_session_id TEXT NOT NULL UNIQUE CHECK (char_length(openai_session_id) BETWEEN 1 AND 256),
    direction TEXT NOT NULL CHECK (direction IN ('outbound', 'inbound')),
    status TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'ringing', 'answered', 'failed', 'closed', 'lost')),
    lease_owner TEXT CHECK (char_length(lease_owner) <= 128),
    lease_expires_at TIMESTAMPTZ,
    attach_attempts INTEGER NOT NULL DEFAULT 0 CHECK (attach_attempts >= 0),
    last_event_at TIMESTAMPTZ,
    close_reason TEXT CHECK (char_length(close_reason) <= 128),
    -- Cumulative voice seconds from session.usage.updated; the final value from session.closed.
    usage_seconds NUMERIC CHECK (usage_seconds >= 0),
    failure_code TEXT CHECK (char_length(failure_code) <= 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    UNIQUE (id, workspace_id),
    FOREIGN KEY (voice_call_id, workspace_id) REFERENCES voice_call(id, workspace_id) ON DELETE RESTRICT,
    CHECK ((lease_owner IS NULL) = (lease_expires_at IS NULL)),
    -- A terminal session holds no lease and has a close time.
    CHECK (status IN ('created', 'ringing', 'answered') OR (lease_owner IS NULL AND closed_at IS NOT NULL))
);
-- The worker query: non-terminal sessions whose lease is free or expired.
CREATE INDEX IF NOT EXISTS voice_live_session_worker ON voice_live_session(lease_expires_at)
    WHERE status IN ('created', 'ringing', 'answered');
CREATE INDEX IF NOT EXISTS voice_live_session_workspace ON voice_live_session(workspace_id, created_at DESC);
CREATE INDEX IF NOT EXISTS voice_live_session_call ON voice_live_session(voice_call_id)
    WHERE voice_call_id IS NOT NULL;

-- Conversation text of a live session. The text is AES-256-GCM ciphertext (VoiceKeys::seal_live_secret,
-- bound to the workspace and session), never plaintext, and is purged after the same retention as
-- inbound call data (voice::live::worker::purge_expired_transcripts, run by the voice cleanup task).
CREATE TABLE IF NOT EXISTS voice_live_transcript_segment (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    speaker TEXT NOT NULL CHECK (speaker IN ('caller', 'assistant')),
    start_ms BIGINT NOT NULL CHECK (start_ms >= 0),
    end_ms BIGINT NOT NULL CHECK (end_ms >= start_ms),
    encrypted_text TEXT NOT NULL CHECK (char_length(encrypted_text) BETWEEN 1 AND 262144),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS voice_live_transcript_segment_session
    ON voice_live_transcript_segment(live_session_id, start_ms);
CREATE INDEX IF NOT EXISTS voice_live_transcript_segment_created
    ON voice_live_transcript_segment(created_at);
