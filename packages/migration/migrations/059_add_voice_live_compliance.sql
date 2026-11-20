-- GPT-Live compliance: persona and opt-out settings, human-approved outbound requests and the review queue.
-- Strictly additive: new columns with defaults, new tables and indexes only. Retained audit data must not
-- disappear with a workspace, hence ON DELETE RESTRICT (as in 056-058).

-- Persona and compliance configuration of a workspace. caller_name, voice and opening override the plugin's
-- Const defaults when set; NULL means "use the plugin default". disclose_ai and opt_out_adds_dnc are plain
-- switches that default to OFF. The voice id follows the SessionConfig rule (letters, digits, '_' and '-').
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS caller_name TEXT
    CHECK (char_length(caller_name) BETWEEN 1 AND 64 AND caller_name !~ '[[:cntrl:]]');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS disclose_ai BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS voice TEXT
    CHECK (voice ~ '^[A-Za-z0-9_-]{1,64}$');
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS opening TEXT
    CHECK (char_length(opening) BETWEEN 1 AND 1000);
ALTER TABLE voice_agent_setting ADD COLUMN IF NOT EXISTS opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT FALSE;

-- A human-approved outbound call on the GPT-Live path. There is no unattended dialing here: a call is
-- placed only from a row whose approver is recorded (the CHECK below), and the row is the idempotency
-- anchor, so the OpenAI create request (which places a real call and is never retried) is sent at most once.
-- The destination is sealed like the numbers of call list entries (VoiceKeys::seal_destination) and kept
-- with its HMAC and last four digits, so the opt-out and review paths can find the number later.
-- caller_name and disclose_ai are the persona that was in force when the call was placed.
CREATE TABLE IF NOT EXISTS voice_live_call_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    call_list_entry_id UUID REFERENCES voice_call_list_entry(id) ON DELETE SET NULL,
    encrypted_destination TEXT NOT NULL CHECK (char_length(encrypted_destination) BETWEEN 1 AND 1024),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    -- Which path asked for the call. Only 'admin' and 'workflow' requests can be approved; 'auto_dial' is
    -- recorded as refused so the attempt stays visible.
    origin TEXT NOT NULL DEFAULT 'admin' CHECK (origin IN ('admin', 'workflow', 'auto_dial')),
    requested_by UUID NOT NULL REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    approved_at TIMESTAMPTZ,
    state TEXT NOT NULL DEFAULT 'pending_approval' CHECK (state IN (
        'pending_approval', 'approved', 'refused', 'dispatching', 'dispatched', 'ambiguous', 'failed', 'cancelled'
    )),
    -- Why a request is refused or failed, or what made it ambiguous. A machine-readable code only.
    refusal_code TEXT CHECK (char_length(refusal_code) BETWEEN 1 AND 64),
    live_session_id UUID,
    idempotency_key TEXT NOT NULL CHECK (char_length(idempotency_key) BETWEEN 8 AND 128),
    caller_name TEXT CHECK (char_length(caller_name) BETWEEN 1 AND 64),
    disclose_ai BOOLEAN NOT NULL DEFAULT FALSE,
    dispatch_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, idempotency_key),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    -- No call may be started, or be in an unknown state, without a recorded human approver.
    CHECK (state NOT IN ('dispatching', 'dispatched', 'ambiguous') OR approved_by IS NOT NULL),
    CHECK ((approved_by IS NULL) = (approved_at IS NULL)),
    CHECK (state NOT IN ('refused', 'failed') OR refusal_code IS NOT NULL),
    CHECK (state <> 'dispatched' OR live_session_id IS NOT NULL),
    CHECK (state NOT IN ('dispatching', 'dispatched', 'ambiguous') OR dispatch_started_at IS NOT NULL),
    CHECK (origin <> 'auto_dial' OR state = 'refused')
);
-- One request per number may be waiting or starting at a time (the pre-dial gate checks the rest).
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_call_request_in_flight
    ON voice_live_call_request(workspace_id, destination_hash)
    WHERE state IN ('pending_approval', 'approved', 'dispatching');
CREATE INDEX IF NOT EXISTS voice_live_call_request_workspace
    ON voice_live_call_request(workspace_id, created_at DESC, id DESC);
CREATE UNIQUE INDEX IF NOT EXISTS voice_live_call_request_session
    ON voice_live_call_request(live_session_id) WHERE live_session_id IS NOT NULL;

-- The end of the calling window a live session was admitted into (Admission::window_end of the pre-dial gate).
-- The session driver hangs the call up when it passes, so a call that starts inside the calling hours cannot go
-- on after they end. NULL: no window was recorded for the session (an inbound session).
ALTER TABLE voice_live_session ADD COLUMN IF NOT EXISTS window_ends_at TIMESTAMPTZ;

-- Human review queue of the live path: what needs a person's decision. A row holds references and a short
-- machine-readable reason only, never transcript text, CRM data or a number. delegation_id is '' for a
-- session-level item (an opt-out heard on the call). Approving a dnc_request or opt_out item adds the
-- destination of the session's call request to voice_suppression (a human action); the other kinds are
-- acknowledged only.
CREATE TABLE IF NOT EXISTS voice_live_review (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    live_session_id UUID NOT NULL,
    delegation_id TEXT NOT NULL DEFAULT '' CHECK (char_length(delegation_id) <= 256),
    kind TEXT NOT NULL CHECK (kind IN ('dnc_request', 'opt_out', 'disallowed_op', 'screened_output')),
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'approved', 'dismissed')),
    reason TEXT CHECK (char_length(reason) BETWEEN 1 AND 128),
    tool_execution_id UUID,
    decided_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    decided_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (live_session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (live_session_id, delegation_id, kind),
    CHECK ((status = 'open') = (decided_at IS NULL)),
    CHECK (status = 'open' OR decided_by IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS voice_live_review_workspace
    ON voice_live_review(workspace_id, status, created_at DESC, id DESC);
