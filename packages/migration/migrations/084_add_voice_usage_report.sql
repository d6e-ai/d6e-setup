-- The queue of finished voice calls that are reported to d6e.ai, which counts voice by the minute.
-- One row per call. What is sent is built from the call when it is delivered; the row keeps only
-- where the delivery stands. No phone number is kept here.
--   state            pending (to deliver), sent, skipped (a call with no seconds: it is not counted)
--                    or failed (given up after the attempts, for a person to look at).
--   attempts         how many times a delivery was started.
--   next_attempt_at  when a pending row is due; a claimed row is held from other processes until then.
--   last_status      the HTTP status of the last answer, none when there was no answer.
--   note             a short code (not a message): no_usage, session_gone, refused, not_delivered ...
CREATE TABLE IF NOT EXISTS voice_usage_report (
    session_id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'skipped', 'failed')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    last_status INTEGER CHECK (last_status BETWEEN 100 AND 599),
    note TEXT CHECK (char_length(note) BETWEEN 1 AND 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (session_id, workspace_id) REFERENCES voice_live_session(id, workspace_id) ON DELETE CASCADE,
    CHECK ((state = 'sent') = (sent_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS voice_usage_report_due
    ON voice_usage_report(next_attempt_at) WHERE state = 'pending';

-- The 050 numbers this server holds for voice, reported to d6e.ai, which bills every month a number
-- is held and the month it was taken. One row per stretch of time a connection held one: it opens
-- when a connection is saved with a 050 caller number (or is found holding one) and closes when the
-- connection is deleted or saved with another number. The row's id is what d6e.ai knows the number
-- by. No phone number is kept here.
--   active_from, active_to  when the connection started and stopped holding the number (whole seconds).
--   revision         counts the changes of the row; a delivery settles only the revision it sent.
--   lease_until      while a delivery is under way, how long it may take; a change waits for it, so an
--                    older report can never arrive after a newer one.
--   state ... note   as in voice_usage_report; skipped is a stretch that ended before reporting began.
CREATE TABLE IF NOT EXISTS voice_number_report (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE RESTRICT,
    connection_id UUID NOT NULL REFERENCES voice_live_connection(id) ON DELETE RESTRICT,
    active_from TIMESTAMPTZ NOT NULL,
    active_to TIMESTAMPTZ,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'skipped', 'failed')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    lease_until TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    last_status INTEGER CHECK (last_status BETWEEN 100 AND 599),
    note TEXT CHECK (char_length(note) BETWEEN 1 AND 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (active_to IS NULL OR active_to > active_from),
    CHECK ((state = 'sent') = (sent_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_number_report_open
    ON voice_number_report(connection_id) WHERE active_to IS NULL;
CREATE INDEX IF NOT EXISTS voice_number_report_due
    ON voice_number_report(next_attempt_at) WHERE state = 'pending';
