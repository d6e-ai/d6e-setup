-- Record which user a chat session belongs to. Sessions stay visible to every workspace member as before;
-- the column makes ownership available ( for display, export and moving a workspace to Lite, whose chats
-- are per user ). Existing rows are filled from the chat-session `create` audit events where present;
-- older sessions keep NULL ( unknown ).
ALTER TABLE frontend.chat_session ADD COLUMN IF NOT EXISTS user_id UUID;

CREATE INDEX IF NOT EXISTS idx_frontend_chat_session_workspace_user
    ON frontend.chat_session (workspace_id, user_id);

UPDATE frontend.chat_session session
SET user_id = created.user_id
FROM (
    SELECT DISTINCT ON (resource_id) resource_id, user_id
    FROM public.audit_log
    WHERE resource_type = 'chat_session' AND action = 'create' AND resource_id IS NOT NULL
    ORDER BY resource_id, created_at, id
) created
WHERE session.id = created.resource_id AND session.user_id IS NULL;
