-- A LiveKit inbound call uses the same voice_live_session row as GPT-Live, so post-call and
-- history stay on the internal id. The room name stays in voice_livekit_call. GPT-Live rows
-- still require openai_session_id. LiveKit rows leave it null. A room name is not unique: a
-- later call may reuse the name of a call that ended, so the app keeps one live session per room.

ALTER TABLE voice_live_connection
    ADD COLUMN IF NOT EXISTS conversation_runtime TEXT NOT NULL DEFAULT 'gpt_live'
        CHECK (conversation_runtime IN ('gpt_live', 'livekit'));

ALTER TABLE voice_live_session
    ADD COLUMN IF NOT EXISTS conversation_runtime TEXT NOT NULL DEFAULT 'gpt_live'
        CHECK (conversation_runtime IN ('gpt_live', 'livekit'));

ALTER TABLE voice_live_session ALTER COLUMN openai_session_id DROP NOT NULL;

ALTER TABLE voice_live_session DROP CONSTRAINT IF EXISTS voice_live_session_runtime_session_id;
ALTER TABLE voice_live_session ADD CONSTRAINT voice_live_session_runtime_session_id CHECK (
    (conversation_runtime = 'gpt_live' AND openai_session_id IS NOT NULL)
    OR (conversation_runtime = 'livekit' AND openai_session_id IS NULL)
);

CREATE TABLE IF NOT EXISTS voice_livekit_call (
    session_id UUID PRIMARY KEY REFERENCES voice_live_session(id) ON DELETE RESTRICT,
    workspace_id UUID NOT NULL,
    room_name TEXT NOT NULL CHECK (char_length(room_name) BETWEEN 1 AND 128),
    sip_participant_id TEXT CHECK (sip_participant_id IS NULL OR char_length(sip_participant_id) BETWEEN 1 AND 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT
);
-- The first revision of this migration made room_name UNIQUE: a database that ran it drops that here.
ALTER TABLE voice_livekit_call DROP CONSTRAINT IF EXISTS voice_livekit_call_room_name_key;
CREATE INDEX IF NOT EXISTS voice_livekit_call_room ON voice_livekit_call(room_name);
