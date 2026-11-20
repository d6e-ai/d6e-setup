-- Add workspace-level settings for automatic embedding.
-- When enabled, file uploads and SQL INSERT/UPDATE operations
-- automatically trigger embedding jobs for configured targets.
ALTER TABLE workspace
    ADD COLUMN IF NOT EXISTS auto_embed_files BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS auto_embed_tables BOOLEAN NOT NULL DEFAULT FALSE;
