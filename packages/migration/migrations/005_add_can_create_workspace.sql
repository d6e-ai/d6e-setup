-- Migration: Add can_create_workspace flag to user table.
-- When WORKSPACE_CREATION_OPEN is false, only users with this flag
-- set to true can create new workspaces (admin-granted permission).

ALTER TABLE public."user"
    ADD COLUMN IF NOT EXISTS can_create_workspace BOOLEAN NOT NULL DEFAULT false;
