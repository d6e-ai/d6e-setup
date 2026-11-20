-- Migration: Google Drive local mirror sync tables.
--
-- Overview:
-- Stores a synced copy of Google Drive folders/files so the LLM does not have to
-- call the Drive API on every access. The folder hierarchy is preserved as an
-- adjacency list (parent_id) plus a materialized `path` column, all inside the
-- `frontend` schema (source of truth). File bytes are cached on demand into
-- public.storage_file and referenced via storage_file_id.
--
-- An LLM-facing projection table (user_data.ws_<workspace>_drive_files) is created
-- per workspace by the sync engine at runtime, not here, because user_data tables
-- are namespaced per workspace and queried through d6e_sql.
--
-- Constraints:
-- - drive_sync_config holds one row per workspace (sync settings + last status).
-- - drive_sync_root holds the starting folders / shared drives chosen by the user;
--   start_page_token is the incremental-sync cursor for the Drive changes API.
-- - drive_sync_node holds every synced node; UNIQUE(workspace_id, drive_id) makes
--   upserts idempotent. parent_id is self-referential for the tree structure.

-- Per-workspace sync configuration (one row per workspace).
CREATE TABLE IF NOT EXISTS frontend.drive_sync_config (
    workspace_id UUID PRIMARY KEY REFERENCES workspace(id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    sync_interval_seconds INTEGER NOT NULL DEFAULT 900,
    last_synced_at TIMESTAMPTZ,
    last_sync_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sync roots: starting folders or shared drives selected by the user.
CREATE TABLE IF NOT EXISTS frontend.drive_sync_root (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    -- Google folder id, shared drive id, or the literal 'root' for My Drive.
    drive_id TEXT NOT NULL,
    drive_type TEXT NOT NULL CHECK (drive_type IN ('folder', 'shared_drive', 'my_drive')),
    name TEXT NOT NULL,
    -- Enclosing shared drive id when the root lives inside a shared drive; the
    -- Drive changes API requires it to scope incremental polling to that drive.
    shared_drive_id TEXT,
    -- Incremental sync cursor (Drive changes API start page token), per drive.
    start_page_token TEXT,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, drive_id)
);

CREATE INDEX IF NOT EXISTS idx_drive_sync_root_workspace
    ON frontend.drive_sync_root(workspace_id);

-- Synced tree nodes (source of truth). Adjacency list via parent_id plus a
-- materialized `path` for prefix queries such as path LIKE '/業務/契約/%'.
CREATE TABLE IF NOT EXISTS frontend.drive_sync_node (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    root_id UUID NOT NULL REFERENCES frontend.drive_sync_root(id) ON DELETE CASCADE,
    -- Google Drive file/folder id.
    drive_id TEXT NOT NULL,
    parent_id UUID REFERENCES frontend.drive_sync_node(id) ON DELETE SET NULL,
    parent_drive_id TEXT,
    name TEXT NOT NULL,
    -- Materialized path from the root, e.g. /業務/2024/契約.pdf
    path TEXT NOT NULL,
    is_folder BOOLEAN NOT NULL,
    mime_type TEXT NOT NULL,
    size BIGINT NOT NULL DEFAULT 0,
    drive_modified_time TIMESTAMPTZ,
    md5_checksum TEXT,
    -- Cached file bytes (NULL until materialized on demand).
    storage_file_id UUID REFERENCES storage_file(id) ON DELETE SET NULL,
    -- drive_modified_time captured when the bytes were cached, used to detect
    -- staleness and trigger re-download.
    cached_modified_time TIMESTAMPTZ,
    trashed BOOLEAN NOT NULL DEFAULT FALSE,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, drive_id)
);

CREATE INDEX IF NOT EXISTS idx_drive_sync_node_workspace
    ON frontend.drive_sync_node(workspace_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_root
    ON frontend.drive_sync_node(root_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_parent
    ON frontend.drive_sync_node(parent_id);
CREATE INDEX IF NOT EXISTS idx_drive_sync_node_path
    ON frontend.drive_sync_node(workspace_id, path);
