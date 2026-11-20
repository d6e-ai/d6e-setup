-- Migration: Allow Google Drive "Shared with me" folders as sync roots.
--
-- Overview:
-- Personal Google accounts cannot use Shared drives. Files and folders that
-- others share with the user appear under Shared with me instead. This
-- migration extends drive_sync_root.drive_type so those folders can be
-- registered as sync roots (drive_type = 'shared_with_me').
--
-- Constraints:
-- - Existing roots keep their drive_type; only the CHECK list grows.
-- - The previous CHECK name is looked up dynamically because PostgreSQL
--   auto-names inline CHECKs as {table}_{column}_check.

DO $$
DECLARE
    cname text;
BEGIN
    SELECT conname INTO cname
    FROM pg_constraint
    WHERE conrelid = 'frontend.drive_sync_root'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%drive_type%';

    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE frontend.drive_sync_root DROP CONSTRAINT %I', cname);
    END IF;

    ALTER TABLE frontend.drive_sync_root
        ADD CONSTRAINT drive_sync_root_drive_type_check
        CHECK (drive_type IN ('folder', 'shared_drive', 'my_drive', 'shared_with_me'));
END $$;
