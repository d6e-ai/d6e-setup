-- Migration: track last-access time of cached Drive file bytes.
--
-- Overview:
-- Adds frontend.drive_sync_node.cache_accessed_at so the on-demand content cache
-- (storage_file_id) can be evicted on a time-to-live basis. The column is stamped
-- whenever a node's bytes are materialized or reused (a cache hit) by the read
-- path (d6e_read_drive_file / materialize). A background cleanup task hard-deletes
-- storage_file rows whose linked node has not been accessed within the TTL and
-- clears storage_file_id / cached_modified_time / cache_accessed_at so the next
-- read re-materializes the bytes from Drive.
--
-- Constraints:
-- - Nullable: existing cached rows simply have no access time until next read.
-- - Partial index supports the TTL cleanup scan over currently-cached nodes only.

ALTER TABLE frontend.drive_sync_node
    ADD COLUMN IF NOT EXISTS cache_accessed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_drive_sync_node_cache_accessed
    ON frontend.drive_sync_node(cache_accessed_at)
    WHERE storage_file_id IS NOT NULL;
