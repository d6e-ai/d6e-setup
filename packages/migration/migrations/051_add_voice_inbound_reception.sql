-- Voice inbound reception v1: reception and callback handling only (no voicemail, no transfer).
-- Additive: new tables and nullable or defaulted columns, plus one widened CHECK. It does not
-- depend on 050 and can be applied before or after it. Phone numbers are stored only as an
-- AES-GCM ciphertext (workspace-bound), an HMAC and the last four digits; never in plain text.

-- One row per workspace; absent means the defaults below.
CREATE TABLE IF NOT EXISTS voice_inbound_policy (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo' CHECK (char_length(timezone) BETWEEN 1 AND 64),
    windows JSONB NOT NULL DEFAULT '[{"weekdays":[1,2,3,4,5],"start":"09:00","end":"18:00"}]'::jsonb
        CHECK (jsonb_typeof(windows) = 'array' AND jsonb_array_length(windows) BETWEEN 1 AND 8),
    -- Spoken by d6e outside the windows (say, then hang up); no turn workflow runs.
    after_hours_message TEXT NOT NULL
        DEFAULT 'お電話ありがとうございます。本日の受付は終了しました。恐れ入りますが、受付時間内に改めておかけ直しください。'
        CHECK (char_length(after_hours_message) <= 200 AND length(btrim(after_hours_message)) > 0
            AND after_hours_message !~ '[[:cntrl:]]'),
    max_duration_seconds INTEGER NOT NULL DEFAULT 300 CHECK (max_duration_seconds BETWEEN 30 AND 300),
    -- Answered calls (connected or after-hours message) per policy-timezone day.
    max_calls_per_day INTEGER NOT NULL DEFAULT 50 CHECK (max_calls_per_day BETWEEN 1 AND 10000),
    -- Answered calls per caller number in any rolling hour.
    per_caller_per_hour INTEGER NOT NULL DEFAULT 3 CHECK (per_caller_per_hour BETWEEN 1 AND 60),
    allow_anonymous BOOLEAN NOT NULL DEFAULT FALSE,
    -- Match callers against the workspace's call lists (caller_match, callback updates).
    -- Off by default: a reservation workspace must never match sales leads.
    match_call_lists BOOLEAN NOT NULL DEFAULT FALSE,
    -- A caller who asks not to be called joins the workspace DNC list (C4). On by default, so
    -- no later outbound call reaches them; a workspace that only receives calls may turn it off.
    opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT TRUE,
    -- Summaries, caller ciphertexts/hashes and attempt rows older than this are purged.
    retention_days INTEGER NOT NULL DEFAULT 90 CHECK (retention_days BETWEEN 1 AND 365),
    -- Optional inbound-only turn workflow (workspace-workflow-v1); NULL uses the shared one.
    inbound_workflow_id UUID CHECK (inbound_workflow_id <> '00000000-0000-0000-0000-000000000000'),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Columns added after the first 051 revision: a database that already ran it gets them here.
ALTER TABLE voice_inbound_policy ADD COLUMN IF NOT EXISTS match_call_lists BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_inbound_policy ADD COLUMN IF NOT EXISTS opt_out_adds_dnc BOOLEAN NOT NULL DEFAULT TRUE;

-- Inbound block list. Separate from voice_suppression: it refuses incoming calls only and never
-- changes outbound DNC or blacklist decisions.
CREATE TABLE IF NOT EXISTS voice_inbound_block (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    caller_hash TEXT NOT NULL CHECK (caller_hash ~ '^[a-f0-9]{64}$'),
    caller_hint TEXT NOT NULL CHECK (caller_hint ~ '^[0-9]{1,4}$'),
    reason TEXT CHECK (char_length(reason) <= 500),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, caller_hash)
);

-- Every decision on an authenticated offer for a workspace that accepts calls, for the rate
-- limit, the daily cap and the admin view. No number, only its HMAC (NULL when anonymous).
CREATE TABLE IF NOT EXISTS voice_inbound_attempt (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    caller_hash TEXT CHECK (caller_hash ~ '^[a-f0-9]{64}$'),
    outcome TEXT NOT NULL CHECK (outcome IN ('connected', 'after_hours', 'rejected', 'busy')),
    reason TEXT CHECK (reason IN ('anonymous', 'blocked', 'caller_rate', 'daily_cap')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK ((outcome = 'rejected') = (reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS voice_inbound_attempt_workspace ON voice_inbound_attempt(workspace_id, created_at);
CREATE INDEX IF NOT EXISTS voice_inbound_attempt_caller ON voice_inbound_attempt(workspace_id, caller_hash, created_at)
    WHERE caller_hash IS NOT NULL;

-- The inbound caller. Outbound rows never carry these.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS encrypted_caller TEXT
    CHECK (char_length(encrypted_caller) BETWEEN 1 AND 1024);
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_hash TEXT CHECK (caller_hash ~ '^[a-f0-9]{64}$');
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_hint TEXT CHECK (caller_hint ~ '^[0-9]{1,4}$');
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS caller_anonymous BOOLEAN NOT NULL DEFAULT FALSE;
-- The call-list entry the caller's number matched (a hint, not identity).
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS matched_entry_id UUID;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call'::regclass AND conname='voice_call_inbound_caller') THEN
        ALTER TABLE voice_call ADD CONSTRAINT voice_call_inbound_caller CHECK (
            (encrypted_caller IS NULL) = (caller_hash IS NULL)
            AND (caller_hash IS NULL) = (caller_hint IS NULL)
            AND (direction = 'inbound' OR (caller_hash IS NULL AND NOT caller_anonymous AND matched_entry_id IS NULL))
            AND NOT (caller_anonymous AND caller_hash IS NOT NULL)
        );
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS voice_call_inbound_caller ON voice_call(workspace_id, caller_hash, created_at)
    WHERE direction = 'inbound' AND caller_hash IS NOT NULL;

-- The final action's call summary (contract C2). Admin-only; purged after retention_days.
CREATE TABLE IF NOT EXISTS voice_inbound_summary (
    call_id UUID PRIMARY KEY REFERENCES voice_call(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    next_action TEXT NOT NULL
        CHECK (next_action IN ('none', 'callback', 'email', 'meeting', 'human_review', 'block')),
    outcome TEXT NOT NULL CHECK (outcome IN ('inquiry', 'callback_requested', 'meeting_requested',
        'email_ok', 'callback_done', 'not_interested', 'declined', 'spam', 'review')),
    summary TEXT CHECK (char_length(summary) <= 1000),
    preferred_time TEXT CHECK (char_length(preferred_time) <= 200),
    email TEXT CHECK (char_length(email) <= 200),
    contact_name TEXT CHECK (char_length(contact_name) <= 200),
    company TEXT CHECK (char_length(company) <= 200),
    -- Kept only when it is the lead d6e matched for this call.
    matched_lead_id TEXT CHECK (char_length(matched_lead_id) BETWEEN 1 AND 200),
    callback_resolved BOOLEAN NOT NULL DEFAULT FALSE,
    -- What d6e did to the call lists (contract C3).
    list_update TEXT NOT NULL DEFAULT 'none' CHECK (list_update IN ('none', 'callback_done', 'callback_kept')),
    entries_updated INTEGER NOT NULL DEFAULT 0 CHECK (entries_updated >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_inbound_summary_workspace ON voice_inbound_summary(workspace_id, created_at DESC);

-- 'callback_done': a callback the lead's own call resolved. Terminal: it never returns to
-- pending, so it is never auto-dialed (voice_unattended_refusal refuses every non-pending entry).
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS callback_preferred_time TEXT
    CHECK (char_length(callback_preferred_time) <= 200);
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS callback_resolved_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS voice_call_list_entry_caller ON voice_call_list_entry(workspace_id, destination_hash);
-- Widens 049's inline status CHECK (049 itself is not edited). Guarded: runs only while the
-- constraint lacks 'callback_done'. Added NOT VALID, then validated.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'voice_call_list_entry'::regclass AND conname = 'voice_call_list_entry_status_check'
          AND pg_get_constraintdef(oid) LIKE '%callback_done%' AND convalidated
    ) THEN
        ALTER TABLE voice_call_list_entry DROP CONSTRAINT IF EXISTS voice_call_list_entry_status_check;
        ALTER TABLE voice_call_list_entry ADD CONSTRAINT voice_call_list_entry_status_check CHECK (
            status IN ('pending', 'calling', 'called', 'skipped', 'failed', 'suppressed', 'callback', 'callback_done')
        ) NOT VALID;
        ALTER TABLE voice_call_list_entry VALIDATE CONSTRAINT voice_call_list_entry_status_check;
    END IF;
END $$;
