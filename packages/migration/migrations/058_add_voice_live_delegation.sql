-- GPT-Live client delegation: agent settings, CRM binding, delegation log and tool ledger.
-- Strictly additive: new tables and indexes only. Retained audit data must not disappear with a
-- workspace, hence ON DELETE RESTRICT (as in 056/057).
-- Workflow ids are plain UUIDs without a foreign key, like voice_inbound_policy.inbound_workflow_id (051):
-- the admin API checks the workflow when the setting is saved and the runner checks it again when it runs.

-- One active agent setting per workspace (PR-4 adds caller name, AI disclosure and opt-out handling).
-- fast_model answers a delegation within a short deadline; slow_model is handed to the delegate workflow.
-- Model ids follow gateway_client::valid_model_id: no whitespace, control characters or URLs.
CREATE TABLE IF NOT EXISTS voice_agent_setting (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    fast_model TEXT NOT NULL CHECK (
        char_length(fast_model) BETWEEN 1 AND 256 AND fast_model !~ '[[:space:][:cntrl:]]' AND fast_model !~ '://'
    ),
    slow_model TEXT CHECK (
        char_length(slow_model) BETWEEN 1 AND 256 AND slow_model !~ '[[:space:][:cntrl:]]' AND slow_model !~ '://'
    ),
    context_workflow_id UUID CHECK (context_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    delegate_workflow_id UUID CHECK (delegate_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    post_call_workflow_id UUID CHECK (post_call_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_agent_setting_workspace_active
    ON voice_agent_setting(workspace_id) WHERE deleted_at IS NULL;

-- Where the CRM tools may read and write. The table and every column come from this row only (never from
-- model output); values are always bound parameters. One active binding per workspace. The identifier
-- checks here are repeated in Rust (voice::live::crm) before any SQL is built.
CREATE TABLE IF NOT EXISTS voice_crm_binding (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 128 AND name !~ '[[:cntrl:]]'),
    -- A workspace-SQL table (not a physical table name): rewritten into the workspace namespace on execution.
    target_table TEXT NOT NULL CHECK (target_table ~ '^[a-z_][a-z0-9_]{0,62}$'),
    key_column TEXT NOT NULL CHECK (key_column ~ '^[a-z_][a-z0-9_]{0,62}$'),
    phone_column TEXT CHECK (phone_column ~ '^[a-z_][a-z0-9_]{0,62}$'),
    -- Logical field -> column: only status, notes, next_action and callback_at, each a plain identifier.
    column_map JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (
        jsonb_typeof(column_map) = 'object'
        AND NOT jsonb_path_exists(column_map, '$.keyvalue() ? (@.key != "status" && @.key != "notes" && @.key != "next_action" && @.key != "callback_at")')
        AND NOT jsonb_path_exists(column_map, '$.* ? (@.type() != "string")')
        AND NOT jsonb_path_exists(column_map, '$.* ? (!(@ like_regex "^[a-z_][a-z0-9_]{0,62}$"))')
    ),
    allowed_ops TEXT[] NOT NULL CHECK (
        cardinality(allowed_ops) BETWEEN 1 AND 4
        AND allowed_ops <@ ARRAY['lookup', 'update_status', 'log_activity', 'schedule_callback']::text[]
    ),
    -- update_status may only write one of these.
    allowed_statuses TEXT[] NOT NULL DEFAULT '{}'::text[] CHECK (
        cardinality(allowed_statuses) <= 32 AND array_to_string(allowed_statuses, '') !~ '[[:cntrl:]]'
    ),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    -- An allowed write needs its column (and, for update_status, at least one allowed status).
    CHECK (NOT ('update_status' = ANY(allowed_ops)) OR (column_map ->> 'status' IS NOT NULL AND cardinality(allowed_statuses) >= 1)),
    CHECK (NOT ('log_activity' = ANY(allowed_ops)) OR column_map ->> 'notes' IS NOT NULL),
    CHECK (NOT ('schedule_callback' = ANY(allowed_ops)) OR column_map ->> 'callback_at' IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_crm_binding_workspace_active
    ON voice_crm_binding(workspace_id) WHERE deleted_at IS NULL;

-- One row per delegation of a live session. Inserted when the delegation is claimed (which makes a replayed
-- session.delegation.created a no-op) and completed when the answer was appended.
CREATE TABLE IF NOT EXISTS voice_delegation (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL CHECK (char_length(delegation_id) BETWEEN 1 AND 256),
    route TEXT NOT NULL DEFAULT 'fast' CHECK (route IN ('fast', 'slow', 'supervisor')),
    model TEXT CHECK (char_length(model) <= 256),
    latency_ms INTEGER CHECK (latency_ms >= 0),
    result_kind TEXT NOT NULL DEFAULT 'none' CHECK (result_kind IN ('commentary', 'thinking', 'none', 'needs_review', 'error')),
    error_code TEXT CHECK (char_length(error_code) <= 128),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id)
);
CREATE INDEX IF NOT EXISTS voice_delegation_workspace ON voice_delegation(workspace_id, created_at DESC);

-- Tool ledger of live sessions (voice_tool_execution is bound to the call/turn/session_generation model, which
-- live sessions do not have). The idempotency key is delegation_id + tool. 'started' is written before the
-- tool runs, so a crash mid-write is never repeated blindly (it stays 'started'/'unknown' for a human).
-- A needs_review row is a request for a human decision: the tool is never executed for it. It holds
-- references and hashes only, never CRM data.
CREATE TABLE IF NOT EXISTS voice_live_tool_execution (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL CHECK (char_length(delegation_id) BETWEEN 1 AND 256),
    tool TEXT NOT NULL CHECK (tool IN (
        'crm.lookup', 'crm.update_status', 'crm.log_activity', 'crm.schedule_callback', 'supervisor.review'
    )),
    -- Why a supervisor.review row exists.
    review_reason TEXT CHECK (review_reason IN ('dnc', 'opt_out', 'not_allowed', 'sensitive')),
    input_hash TEXT NOT NULL CHECK (input_hash ~ '^[a-f0-9]{64}$'),
    state TEXT NOT NULL DEFAULT 'started' CHECK (state IN ('started', 'completed', 'unknown')),
    outcome TEXT CHECK (outcome IN ('applied', 'no_action', 'needs_review')),
    result_reference UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id, tool),
    CHECK ((state = 'completed') = (outcome IS NOT NULL)),
    CHECK ((tool = 'supervisor.review') = (review_reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS voice_live_tool_execution_review
    ON voice_live_tool_execution(workspace_id, created_at DESC) WHERE outcome = 'needs_review';
