-- Separate workflows for outbound calls, so one workspace can run an inbound plugin (for example
-- d6e/voice-inbound) and an outbound plugin (d6e/voice-outbound) side by side.
--   outbound_*_workflow_id  used for outbound calls when set.
--   outbound_opening        the outbound opening, overriding the plugin's (as `opening` does).
--   outbound_separate       false (default, as before): an outbound slot left empty uses the shared
--                           workflow (and the shared opening). true: outbound calls use only the
--                           outbound slots; an empty one means none, so an inbound workflow is never
--                           run for an outbound call.
-- Inbound calls keep using the shared columns. Existing rows behave as before.
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_context_workflow_id UUID
    CHECK (outbound_context_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_delegate_workflow_id UUID
    CHECK (outbound_delegate_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_post_call_workflow_id UUID
    CHECK (outbound_post_call_workflow_id <> '00000000-0000-0000-0000-000000000000');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_opening TEXT
    CHECK (char_length(outbound_opening) BETWEEN 1 AND 1000);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS outbound_separate BOOLEAN NOT NULL DEFAULT FALSE;
