-- SNS-origin chat sessions: map external conversation (Slack thread, LINE room, etc.)
-- to a single frontend.chat_session row for workspace-scoped history.

ALTER TABLE frontend.chat_session
    ADD COLUMN IF NOT EXISTS sns_source TEXT,
    ADD COLUMN IF NOT EXISTS external_conversation_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS ux_frontend_chat_session_sns_external
    ON frontend.chat_session (workspace_id, sns_source, external_conversation_key)
    WHERE sns_source IS NOT NULL AND external_conversation_key IS NOT NULL;
