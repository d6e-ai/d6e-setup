-- Migration: Add allowed_email table for pre-approving workspace creation
-- permission by email before user registration.
-- When a user signs up with a pre-approved email, they automatically
-- receive can_create_workspace = true.

CREATE TABLE IF NOT EXISTS allowed_email (
    email TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
