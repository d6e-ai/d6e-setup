-- Migration: Add workspace_invitation table for pre-inviting users who have
-- not yet logged in to this d6e instance. When such a user signs in for the
-- first time, the corresponding pending invitations are auto-converted into
-- workspace memberships by apply_pending_invitations() in the API layer.
--
-- Notes:
--   - email is stored lowercased so case-insensitive matching against the
--     JWT-provisioned user.email is trivial at login time.
--   - The (workspace_id, email) uniqueness constraint allows the add_member
--     endpoint to return 409 Conflict for duplicate invites symmetrically
--     with the existing duplicate-membership check.
--   - workspace_id uses ON DELETE CASCADE so removing a workspace also
--     reaps its pending invitations. invited_by uses ON DELETE SET NULL so
--     that pending invitations survive the inviter's account deletion.

CREATE TABLE IF NOT EXISTS workspace_invitation (
    id UUID PRIMARY KEY,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role workspace_role NOT NULL DEFAULT 'member',
    invited_by UUID REFERENCES public."user"(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT workspace_invitation_workspace_email_unique
        UNIQUE (workspace_id, email)
);

-- Login-time lookup keyed by email (apply_pending_invitations scans by
-- the freshly provisioned user's email, then joins on workspace_id).
CREATE INDEX IF NOT EXISTS workspace_invitation_email_idx
    ON workspace_invitation (email);
