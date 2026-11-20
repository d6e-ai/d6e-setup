-- Bring-your-own telephony. Strictly additive: new tables/columns/indexes and DROP NOT NULL only.
-- Nothing is dropped here; the legacy Auth columns are retired by a later, separate migration.
-- Retained call/audit data must not disappear when a workspace is removed, hence ON DELETE RESTRICT.

-- Carrier credentials: write-only, AES-256-GCM ciphertext (crate::crypto). Never returned by any API.
CREATE TABLE IF NOT EXISTS voice_provider_connection (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL UNIQUE REFERENCES workspace(id) ON DELETE RESTRICT,
    provider TEXT NOT NULL CHECK (provider IN ('twilio')),
    -- NULL only once soft-deleted and no call can still need it (see credentials::delete_connection).
    encrypted_secret TEXT CHECK (char_length(encrypted_secret) BETWEEN 1 AND 8192),
    key_hint TEXT CHECK (char_length(key_hint) <= 64),
    account_ref TEXT CHECK (char_length(account_ref) <= 128),
    caller_id TEXT CHECK (caller_id ~ '^\+[1-9][0-9]{7,14}$'),
    caller_id_status TEXT NOT NULL DEFAULT 'unknown' CHECK (caller_id_status IN ('owned', 'verified', 'unknown')),
    verified_at TIMESTAMPTZ,
    caller_id_checked_at TIMESTAMPTZ,
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CHECK (deleted_at IS NOT NULL OR encrypted_secret IS NOT NULL)
);

-- Per-workspace outbound safety policy, enforced by voice::policy::admit_outbound.
CREATE TABLE IF NOT EXISTS voice_calling_policy (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE RESTRICT,
    timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo' CHECK (char_length(timezone) BETWEEN 1 AND 64),
    windows JSONB NOT NULL DEFAULT '[{"weekdays":[1,2,3,4,5,6,7],"start":"08:00","end":"22:00"}]'::jsonb
        CHECK (jsonb_typeof(windows) = 'array' AND jsonb_array_length(windows) BETWEEN 1 AND 8),
    allowed_prefixes TEXT[] NOT NULL DEFAULT '{+81}'
        CHECK (cardinality(allowed_prefixes) BETWEEN 1 AND 32),
    -- The 045 partial unique index voice_call_workspace_active allows one active call per workspace.
    -- Raising this limit needs a later migration that relaxes that index.
    max_concurrent_calls INTEGER NOT NULL DEFAULT 1 CHECK (max_concurrent_calls = 1),
    max_calls_per_day INTEGER NOT NULL DEFAULT 50 CHECK (max_calls_per_day BETWEEN 1 AND 10000),
    version BIGINT NOT NULL DEFAULT 1 CHECK (version > 0),
    updated_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- DNC and blacklist: only an HMAC of the destination is stored, plus the last 4 digits for display.
CREATE TABLE IF NOT EXISTS voice_suppression (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    kind TEXT NOT NULL CHECK (kind IN ('dnc', 'blacklist')),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    reason TEXT CHECK (char_length(reason) <= 500),
    source TEXT NOT NULL CHECK (source IN ('manual', 'call_opt_out', 'plugin', 'import')),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, kind, destination_hash)
);
CREATE INDEX IF NOT EXISTS voice_suppression_lookup ON voice_suppression(workspace_id, destination_hash);

CREATE TABLE IF NOT EXISTS voice_call_list (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    description TEXT CHECK (char_length(description) <= 1000),
    created_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at TIMESTAMPTZ,
    UNIQUE (id, workspace_id)
);
CREATE INDEX IF NOT EXISTS voice_call_list_workspace ON voice_call_list(workspace_id, created_at DESC);

-- The destination is needed to dial, so it is kept encrypted; the hash is for matching and dedupe only.
CREATE TABLE IF NOT EXISTS voice_call_list_entry (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    list_id UUID NOT NULL,
    workspace_id UUID NOT NULL,
    encrypted_destination TEXT NOT NULL CHECK (char_length(encrypted_destination) BETWEEN 1 AND 1024),
    destination_hash TEXT NOT NULL CHECK (destination_hash ~ '^[a-f0-9]{64}$'),
    destination_hint TEXT NOT NULL CHECK (destination_hint ~ '^[0-9]{1,4}$'),
    display_name TEXT CHECK (char_length(display_name) <= 200),
    lead_context JSONB CHECK (octet_length(lead_context::text) <= 8192),
    status TEXT NOT NULL DEFAULT 'pending'
        -- 'callback': the lead asked to be called back; called by hand, never dialed unattended.
        CHECK (status IN ('pending', 'calling', 'called', 'skipped', 'failed', 'suppressed', 'callback')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_call_id UUID,
    -- 'deadline' when cleanup closed the entry's last call locally after every deadline passed:
    -- the entry is back in pending if that call never connected, failed otherwise. Cleared when
    -- the entry changes again.
    cleanup_reason TEXT CHECK (cleanup_reason IN ('deadline')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (list_id, workspace_id) REFERENCES voice_call_list(id, workspace_id) ON DELETE RESTRICT,
    UNIQUE (list_id, destination_hash)
);
CREATE INDEX IF NOT EXISTS voice_call_list_entry_pending ON voice_call_list_entry(list_id, created_at, id)
    WHERE status = 'pending';

-- Append-only record of settings changes. detail never holds secrets or phone numbers.
CREATE TABLE IF NOT EXISTS voice_settings_audit (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    actor_user_id UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user', 'api_key', 'service')),
    action TEXT NOT NULL CHECK (char_length(action) BETWEEN 1 AND 128),
    target_kind TEXT NOT NULL CHECK (char_length(target_kind) BETWEEN 1 AND 64),
    target_id UUID,
    detail JSONB NOT NULL DEFAULT '{}'::jsonb CHECK (octet_length(detail::text) <= 8192),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS voice_settings_audit_workspace ON voice_settings_audit(workspace_id, created_at DESC);

-- Provider-neutral call identity. The legacy Auth binding columns become optional.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider TEXT;
-- A connection referenced by any call is never hard-deleted; delete is a soft delete.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_connection_id UUID
    REFERENCES voice_provider_connection(id) ON DELETE RESTRICT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS connection_version BIGINT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_account_ref TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS destination_hash TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS call_list_entry_id UUID;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_expires_at TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS nonce_consumed_at TIMESTAMPTZ;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS price TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS price_unit TEXT;
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_status TEXT;
-- Sticky: the carrier reported the call in progress (answered) at least once. Status reports can
-- arrive out of order, so a later 'ringing' never clears it.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS provider_answered BOOLEAN NOT NULL DEFAULT FALSE;
-- When the dispatch intent committed; the daily limit counts calls by this time.
ALTER TABLE voice_call ADD COLUMN IF NOT EXISTS dispatched_at TIMESTAMPTZ;
ALTER TABLE voice_call ALTER COLUMN binding_id DROP NOT NULL;
ALTER TABLE voice_call ALTER COLUMN configuration_version DROP NOT NULL;
ALTER TABLE voice_workspace_setting ALTER COLUMN binding_id DROP NOT NULL;
ALTER TABLE voice_workspace_setting ALTER COLUMN configuration_version DROP NOT NULL;

-- Carrier call ids are unique per carrier account. The legacy 048 index stays until it is retired.
CREATE UNIQUE INDEX IF NOT EXISTS voice_call_provider_call_once
    ON voice_call(provider, provider_account_ref, provider_call_sid)
    WHERE provider IS NOT NULL AND provider_call_sid IS NOT NULL;

-- Unattended calling from workflows (ADR decision 10). Off unless a workspace admin turns it on
-- here AND the instance sets D6E_VOICE_UNATTENDED_CALLS_ENABLED=true. Calls are placed as the
-- admin who turned it on.
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_calling_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_enabled_by UUID
    REFERENCES "user"(id) ON DELETE RESTRICT;
ALTER TABLE voice_workspace_setting ADD COLUMN IF NOT EXISTS unattended_enabled_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_workspace_setting'::regclass AND conname='voice_workspace_unattended_owner') THEN
        ALTER TABLE voice_workspace_setting ADD CONSTRAINT voice_workspace_unattended_owner CHECK (
            NOT unattended_calling_enabled OR (unattended_enabled_by IS NOT NULL AND unattended_enabled_at IS NOT NULL)
        );
    END IF;
END $$;

-- A manual callback remembers the status it replaced, so releasing it restores that status.
ALTER TABLE voice_call_list_entry ADD COLUMN IF NOT EXISTS status_before_callback TEXT
    CHECK (status_before_callback IN ('pending', 'called', 'skipped', 'failed', 'suppressed'));
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call_list_entry'::regclass AND conname='voice_call_list_entry_callback_restore') THEN
        ALTER TABLE voice_call_list_entry ADD CONSTRAINT voice_call_list_entry_callback_restore CHECK (
            (status = 'callback') = (status_before_callback IS NOT NULL)
        );
    END IF;
END $$;

-- A lead status compared the way the voice-sales plugin compares it (normStatus): NFKC, trimmed,
-- lowercased, runs of spaces, hyphens and underscores folded to one underscore.
CREATE OR REPLACE FUNCTION voice_lead_status(p_status TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(
        regexp_replace(lower(normalize(COALESCE(p_status, ''), NFKC)), '^\s+|\s+$', '', 'g'),
        '[\s_-]+', '_', 'g')
$$;

-- Why an entry may not be dialed unattended, or NULL when it may. These are the dial.mjs rules,
-- kept in the database: the guard trigger below, the dialer's selection query and its check just
-- before each dial all use this one function. Lead statuses rank like the plugin's: a refusal
-- (DNC) over "not interested" (blacklist) over a callback request.
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
        -- A callback request is called back by hand (the manual callback list), never auto-dialed.
        WHEN e.status = 'callback'
            OR voice_lead_status(e.lead_context #>> '{lead,status}') IN ('call_callback', 'callback', '折り返し希望')
            THEN 'callback'
        WHEN EXISTS (SELECT 1 FROM voice_call c WHERE c.workspace_id = e.workspace_id
                AND c.call_list_entry_id = e.id AND c.state IN ('reservation_unknown', 'submission_unknown'))
            THEN 'unknown_outcome'
        -- Unattended calling never redials: only entries that were never called qualify.
        WHEN e.last_call_id IS NOT NULL OR e.attempts > 0 OR EXISTS (SELECT 1 FROM voice_call c
                WHERE c.workspace_id = e.workspace_id AND c.call_list_entry_id = e.id) THEN 'already_called'
        WHEN e.status <> 'pending' THEN 'not_pending'
        WHEN NULLIF(btrim(e.lead_context #>> '{lead,lead_id}'), '') IS NULL THEN 'no_lead_id'
    END
    FROM (SELECT 1) AS one
    LEFT JOIN voice_call_list_entry e ON e.workspace_id = p_workspace AND e.id = p_entry
    LEFT JOIN voice_call_list l ON l.id = e.list_id AND l.workspace_id = e.workspace_id
$$;

-- Queue of the voice.place_call workflow effect. One row per entry and attempt, so a workflow
-- that runs again does not queue a second dial. The dialer worker uses the row id as the call's
-- request_id, so a retried attempt finds its call instead of dialing again.
CREATE TABLE IF NOT EXISTS voice_place_request (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    entry_id UUID NOT NULL REFERENCES voice_call_list_entry(id) ON DELETE CASCADE,
    attempt INTEGER NOT NULL CHECK (attempt >= 0),
    state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN (
        -- suppressed: refused for DNC or blacklist (terminal).
        'queued', 'dialing', 'existing', 'submitted', 'submission_unknown', 'failed', 'refused', 'skipped', 'suppressed'
    )),
    reason TEXT CHECK (char_length(reason) BETWEEN 1 AND 64),
    call_id UUID,
    workflow_id UUID,
    enqueued_by UUID REFERENCES "user"(id) ON DELETE RESTRICT,
    tries INTEGER NOT NULL DEFAULT 0 CHECK (tries >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, entry_id, attempt),
    CHECK (state NOT IN ('refused', 'skipped', 'suppressed') OR reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS voice_place_request_queued ON voice_place_request(next_attempt_at, created_at)
    WHERE state = 'queued';

-- No row can be queued or claimed for an entry the dial.mjs rules exclude.
CREATE OR REPLACE FUNCTION voice_place_request_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    refusal TEXT;
BEGIN
    IF NEW.state IN ('queued', 'dialing') THEN
        refusal := voice_unattended_refusal(NEW.workspace_id, NEW.entry_id);
        IF refusal IS NOT NULL THEN
            RAISE EXCEPTION 'voice_place_request refused: %', refusal USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER voice_place_request_guard
    BEFORE INSERT OR UPDATE OF state ON voice_place_request
    FOR EACH ROW EXECUTE FUNCTION voice_place_request_guard();

-- Per-list auto-dial (ADR decision 10). Off by default; a workspace admin turns it on with a daily
-- cap, audit-logged. The dialer worker then queues the list's eligible pending entries itself,
-- still behind both unattended gates and every voice_unattended_refusal rule.
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_daily_cap INTEGER NOT NULL DEFAULT 0
    CHECK (auto_dial_daily_cap BETWEEN 0 AND 1000);
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_updated_by UUID
    REFERENCES "user"(id) ON DELETE RESTRICT;
ALTER TABLE voice_call_list ADD COLUMN IF NOT EXISTS auto_dial_updated_at TIMESTAMPTZ;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='voice_call_list'::regclass AND conname='voice_call_list_auto_dial_owner') THEN
        ALTER TABLE voice_call_list ADD CONSTRAINT voice_call_list_auto_dial_owner CHECK (
            NOT auto_dial_enabled
            OR (auto_dial_daily_cap > 0 AND auto_dial_updated_by IS NOT NULL AND auto_dial_updated_at IS NOT NULL)
        );
    END IF;
END $$;
-- Which path queued a request: a workflow's voice.place_call step or the list's auto-dial.
ALTER TABLE voice_place_request ADD COLUMN IF NOT EXISTS origin TEXT NOT NULL DEFAULT 'workflow'
    CHECK (origin IN ('workflow', 'auto_dial'));

-- Replaces 046's gateway CHECKs (046 itself is never edited) so a workspace-workflow-v1 setting can
-- store its turn workflow id. gateway-conversation-v1 is unchanged; workspace-workflow-v1 needs no
-- gateway_model and a canonical, non-nil UUID in agent_instructions; any other profile stores
-- neither. Guarded: runs only while a constraint still has the 046 definition. DROP/ADD CONSTRAINT
-- take an ACCESS EXCLUSIVE lock that is held until the migration's transaction commits, so the
-- VALIDATE scan below runs under that same lock: NOT VALID + VALIDATE here does not reduce locking
-- (it would only help if VALIDATE ran in a later transaction). Both tables are small, so the scan
-- is short; apply 049 in a quiet window.
DO $$
DECLARE
    target RECORD;
    rule TEXT := $rule$(
        (profile_ref = 'gateway-conversation-v1'
            AND gateway_model IS NOT NULL AND octet_length(gateway_model) BETWEEN 1 AND 256
            AND gateway_model !~ '[[:space:][:cntrl:]]'
            AND gateway_model !~ '^[a-zA-Z][a-zA-Z0-9+.-]*:'
            AND position('://' in gateway_model)=0
            AND agent_instructions IS NOT NULL AND octet_length(agent_instructions) BETWEEN 1 AND 4096
            AND length(btrim(agent_instructions, E' \t\n\r')) > 0)
        OR (profile_ref = 'workspace-workflow-v1'
            AND gateway_model IS NULL
            AND agent_instructions IS NOT NULL
            AND agent_instructions ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND agent_instructions <> '00000000-0000-0000-0000-000000000000')
        OR (profile_ref NOT IN ('gateway-conversation-v1', 'workspace-workflow-v1')
            AND gateway_model IS NULL AND agent_instructions IS NULL)
    )$rule$;
BEGIN
    FOR target IN
        SELECT * FROM (VALUES
            ('voice_workspace_setting'::regclass, 'voice_workspace_gateway_config'),
            ('voice_call'::regclass, 'voice_call_gateway_config')
        ) AS t(tbl, name)
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = target.tbl AND conname = target.name
              AND pg_get_constraintdef(oid) LIKE '%workspace-workflow-v1%'
              AND convalidated
        ) THEN
            EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', target.tbl, target.name);
            EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK %s NOT VALID', target.tbl, target.name, rule);
            EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', target.tbl, target.name);
        END IF;
    END LOOP;
END $$;
