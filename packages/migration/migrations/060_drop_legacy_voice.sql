-- Drops the legacy carrier voice schema. DESTRUCTIVE: every table, column and function below belonged to
-- the removed Twilio/Telnyx ConversationRelay path and its dialer; voice was never in production, so nothing
-- is archived. GPT-Live (voice_live_*, voice_agent_setting, voice_crm_binding, voice_delegation), the calling
-- policy, suppression, call lists (the lead source), inbound reception policy/blocks/attempts, and
-- voice_settings_audit stay. Idempotent: every statement is IF EXISTS / IF NOT EXISTS / OR REPLACE.

-- Inbound live sessions keep the caller's HMAC and last four digits so an admin can block a caller from the
-- session list (the number itself is never stored). They replace voice_call.caller_hash / caller_hint and are
-- purged with the inbound retention (voice::reception::purge_expired).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS caller_hash TEXT
    CHECK (caller_hash ~ '^[a-f0-9]{64}$');
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS caller_hint TEXT
    CHECK (caller_hint ~ '^[0-9]{1,4}$');
-- A live session no longer points at a legacy call (the column's composite FK and index go with it).
DROP INDEX IF EXISTS voice_live_session_call;
ALTER TABLE voice_live_session DROP COLUMN IF EXISTS voice_call_id;

-- The lead rules without the rules that read legacy calls (`unknown_outcome`, `already_called`).
-- voice::live::gate::lead_refusal still calls this function.
CREATE OR REPLACE FUNCTION voice_unattended_refusal(p_workspace UUID, p_entry UUID) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN e.id IS NULL OR l.id IS NULL THEN 'entry_not_found'
        WHEN l.archived_at IS NOT NULL THEN 'list_archived'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') IN ('do_not_contact', 'opted_out')
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'dnc') THEN 'do_not_call'
        WHEN voice_lead_status(e.lead_context #>> '{lead,status}') = 'call_not_interested'
            OR EXISTS (SELECT 1 FROM voice_suppression s WHERE s.workspace_id = e.workspace_id
                AND s.destination_hash = e.destination_hash AND s.kind = 'blacklist') THEN 'blacklisted'
        WHEN e.status = 'callback'
            OR voice_lead_status(e.lead_context #>> '{lead,status}') IN ('call_callback', 'callback', '折り返し希望')
            THEN 'callback'
        WHEN e.status <> 'pending' THEN 'not_pending'
        WHEN NULLIF(btrim(e.lead_context #>> '{lead,lead_id}'), '') IS NULL THEN 'no_lead_id'
    END
    FROM (SELECT 1) AS one
    LEFT JOIN voice_call_list_entry e ON e.workspace_id = p_workspace AND e.id = p_entry
    LEFT JOIN voice_call_list l ON l.id = e.list_id AND l.workspace_id = e.workspace_id
$$;

-- Children first. Triggers go with their tables; no CASCADE is needed.
DROP TABLE IF EXISTS voice_business_result_evidence;
DROP TABLE IF EXISTS voice_business_result;
DROP TABLE IF EXISTS voice_tool_execution;
DROP TABLE IF EXISTS voice_provider_event;
DROP TABLE IF EXISTS voice_inbound_event;
DROP TABLE IF EXISTS voice_inbound_summary;
DROP TABLE IF EXISTS voice_envelope_replay;
DROP TABLE IF EXISTS voice_place_request;
DROP TABLE IF EXISTS voice_call;
DROP TABLE IF EXISTS voice_provider_connection;
DROP TABLE IF EXISTS voice_service_grant;
DROP TABLE IF EXISTS voice_workspace_setting;

DROP FUNCTION IF EXISTS voice_business_result_evidence_complete();
DROP FUNCTION IF EXISTS voice_business_result_immutable();
DROP FUNCTION IF EXISTS voice_business_result_project();
DROP FUNCTION IF EXISTS voice_business_result_projection_guard();
DROP FUNCTION IF EXISTS voice_business_result_tool_receipt_guard();
DROP FUNCTION IF EXISTS voice_call_gateway_snapshot_immutable();
DROP FUNCTION IF EXISTS voice_inbound_snapshot_immutable();
DROP FUNCTION IF EXISTS voice_place_request_guard();

-- Call lists: the auto-dial settings and the dialer's bookkeeping on entries. The live path refuses the
-- auto_dial origin explicitly and records its attempts in voice_live_call_request.
ALTER TABLE voice_call_list DROP CONSTRAINT IF EXISTS voice_call_list_auto_dial_owner;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_enabled;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_daily_cap;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_updated_by;
ALTER TABLE voice_call_list DROP COLUMN IF EXISTS auto_dial_updated_at;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS last_call_id;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS attempts;
ALTER TABLE voice_call_list_entry DROP COLUMN IF EXISTS cleanup_reason;

-- The inbound turn workflow was stored for the admin view only; the live path never ran it.
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS inbound_workflow_id;
-- Superseded by voice_agent_setting.opt_out_adds_dnc (default OFF), which the live path reads; caller
-- matching against call lists was part of the legacy inbound summary (C1/C3), which the live path does not do.
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS match_call_lists;
ALTER TABLE voice_inbound_policy DROP COLUMN IF EXISTS opt_out_adds_dnc;
