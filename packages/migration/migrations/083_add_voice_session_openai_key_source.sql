-- Who pays for OpenAI on a call: 'instance' (the server's own key) or 'workspace' (the workspace's own
-- key). It is copied from the connection when the call starts, so it stays true when the connection
-- is changed later. A LiveKit call is always 'instance': the agent runs on its own OPENAI_API_KEY.
-- A call that started before this column has none.
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS openai_key_source TEXT
    CHECK (openai_key_source IN ('instance', 'workspace'));
