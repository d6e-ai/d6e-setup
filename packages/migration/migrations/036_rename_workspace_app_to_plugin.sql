-- Migration: Rename the "App" concept to "Plugin".
--
-- Redistributable packages installed from the marketplace are now called
-- Plugins (aligned with Cursor / Claude / Codex terminology). This renames
-- the frontend.workspace_app table and its app_* columns, index, and
-- constraints to the plugin equivalents. Data is preserved as-is; only
-- identifiers change.
--
-- Notes:
--   - Wrapped in existence checks so the migration is idempotent and safe
--     to run on databases where seed.sql already created the new names.
--   - Constraint names produced by PostgreSQL's default naming scheme are
--     renamed only when present (older databases may predate them).

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'frontend' AND table_name = 'workspace_app'
    ) THEN
        ALTER TABLE frontend.workspace_app RENAME TO workspace_plugin;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'frontend' AND table_name = 'workspace_plugin'
          AND column_name = 'app_namespace'
    ) THEN
        ALTER TABLE frontend.workspace_plugin RENAME COLUMN app_namespace TO plugin_namespace;
        ALTER TABLE frontend.workspace_plugin RENAME COLUMN app_name TO plugin_name;
    END IF;
END $$;

-- Rename the workspace lookup index.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'frontend' AND indexname = 'idx_frontend_workspace_app_workspace'
    ) THEN
        ALTER INDEX frontend.idx_frontend_workspace_app_workspace
            RENAME TO idx_frontend_workspace_plugin_workspace;
    END IF;
END $$;

-- Rename the default-named primary key and unique constraints when present.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'frontend' AND c.conname = 'workspace_app_pkey'
    ) THEN
        ALTER TABLE frontend.workspace_plugin
            RENAME CONSTRAINT workspace_app_pkey TO workspace_plugin_pkey;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'frontend'
          AND c.conname = 'workspace_app_workspace_id_app_namespace_app_name_key'
    ) THEN
        ALTER TABLE frontend.workspace_plugin
            RENAME CONSTRAINT workspace_app_workspace_id_app_namespace_app_name_key
            TO workspace_plugin_workspace_unique;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'frontend' AND c.conname = 'workspace_app_tier_check'
    ) THEN
        ALTER TABLE frontend.workspace_plugin
            RENAME CONSTRAINT workspace_app_tier_check TO workspace_plugin_tier_check;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE n.nspname = 'frontend' AND c.conname = 'workspace_app_workspace_id_fkey'
    ) THEN
        ALTER TABLE frontend.workspace_plugin
            RENAME CONSTRAINT workspace_app_workspace_id_fkey TO workspace_plugin_workspace_id_fkey;
    END IF;
END $$;
