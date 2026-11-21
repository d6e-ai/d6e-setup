-- Workspace-prefix the names of constraints that were named before the SQL API prefixed them.
--
-- The SQL API now stores a named constraint as `ws_{workspace}_{name}` (like index names), because
-- PRIMARY KEY / UNIQUE constraints create an index with the constraint's name in the shared
-- `user_data` schema. DROP CONSTRAINT and `ON CONFLICT ON CONSTRAINT` map a name the same way, so
-- an older unprefixed name has to be renamed for them to find it.
--
-- Renamed: named constraints on workspace tables (`user_data.ws_{workspace}_*`) whose name does not
-- start with the table's workspace prefix and is a name the API accepts (snake_case, at most 23
-- characters, no `pg_` prefix, no trailing or doubled underscore, not a reserved word). Automatic
-- names (`ws_…_code_key`, `ws_…_pkey`) already start with the prefix and are not touched. For a
-- PRIMARY KEY / UNIQUE constraint, PostgreSQL renames its index as well.
-- Kept: any other name (a NOTICE each, except NOT NULL constraints, which PostgreSQL 18 names
-- itself and are only counted). The API keeps such a name unchanged in DROP CONSTRAINT and
-- `ON CONFLICT ON CONSTRAINT`, so it stays usable.
-- Stopped: if a new name is already taken (a relation of the same name for PRIMARY KEY / UNIQUE,
-- or a constraint of the same name on the table), the whole migration fails and renames nothing:
-- a name left unprefixed there could no longer be found by the API. Resolve the listed name (for
-- example rename the other relation) and run it again. The second query below lists such names.
--
-- Safe to run more than once. Each rename takes a short ACCESS EXCLUSIVE lock on its table. Apply
-- it together with the API release that prefixes constraint names: until then, DROP CONSTRAINT /
-- ON CONFLICT ON CONSTRAINT with an older name will not find the constraint.
--
-- Count first (read-only):
--   SELECT c.contype,
--          count(*) FILTER (WHERE c.conname ~ '^[a-z][a-z0-9_]{0,22}$' AND c.conname !~ '__'
--                              AND c.conname !~ '_$' AND c.conname !~ '^pg_') AS to_rename,
--          count(*) AS total
--   FROM pg_constraint c
--   JOIN pg_class t ON t.oid = c.conrelid
--   JOIN pg_namespace n ON n.oid = t.relnamespace
--   WHERE n.nspname = 'user_data' AND c.contype IN ('p', 'u', 'c', 'f', 'n')
--     AND t.relname ~ '^ws_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}_'
--     AND NOT starts_with(c.conname, left(t.relname, 40))
--   GROUP BY 1 ORDER BY 1;
-- Names that would stop it (expected: no rows):
--   SELECT t.relname, c.conname
--   FROM pg_constraint c
--   JOIN pg_class t ON t.oid = c.conrelid
--   JOIN pg_namespace n ON n.oid = t.relnamespace
--   WHERE n.nspname = 'user_data' AND c.contype IN ('p', 'u', 'c', 'f', 'n')
--     AND t.relname ~ '^ws_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}_'
--     AND NOT starts_with(c.conname, left(t.relname, 40))
--     AND c.conname ~ '^[a-z][a-z0-9_]{0,22}$' AND c.conname !~ '__'
--     AND c.conname !~ '_$' AND c.conname !~ '^pg_'
--     AND (c.contype IN ('p', 'u') AND EXISTS (SELECT 1 FROM pg_class x
--            WHERE x.relnamespace = t.relnamespace AND x.relname = left(t.relname, 40) || c.conname)
--          OR EXISTS (SELECT 1 FROM pg_constraint k
--            WHERE k.conrelid = t.oid AND k.conname = left(t.relname, 40) || c.conname));
DO $$
DECLARE
    r RECORD;
    new_name TEXT;
    renamed INT := 0;
    kept INT := 0;
    reserved CONSTANT TEXT[] := ARRAY[
        'select', 'insert', 'update', 'delete', 'drop', 'create', 'alter', 'table', 'from',
        'where', 'join', 'union', 'order', 'group', 'having', 'limit', 'offset', 'values', 'set',
        'into', 'all', 'distinct', 'as', 'on', 'and', 'or', 'not', 'null', 'true', 'false', 'case',
        'when', 'then', 'else', 'end', 'exists', 'in', 'like', 'between', 'is'
    ];
BEGIN
    FOR r IN
        SELECT t.relname AS table_name, c.conname, c.contype, left(t.relname, 40) AS prefix
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'user_data'
          AND c.contype IN ('p', 'u', 'c', 'f', 'n')
          AND t.relname ~ '^ws_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}_'
          AND NOT starts_with(c.conname, left(t.relname, 40))
        ORDER BY 1, 2
    LOOP
        IF r.conname !~ '^[a-z][a-z0-9_]{0,22}$'
            OR r.conname ~ '__'
            OR r.conname ~ '_$'
            OR r.conname ~ '^pg_'
            OR r.conname = ANY (reserved)
        THEN
            kept := kept + 1;
            -- PostgreSQL 18 names NOT NULL constraints itself (`…_not_null`, truncated for long
            -- table names); only count those.
            IF r.contype <> 'n' THEN
                RAISE NOTICE 'kept user_data.%: constraint % (not an API constraint name)',
                    r.table_name, r.conname;
            END IF;
            CONTINUE;
        END IF;

        new_name := r.prefix || r.conname;
        BEGIN
            EXECUTE format(
                'ALTER TABLE user_data.%I RENAME CONSTRAINT %I TO %I',
                r.table_name, r.conname, new_name
            );
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN
            -- Aborts the whole DO block, so no constraint has been renamed.
            RAISE EXCEPTION 'prefix_user_data_constraint_names: cannot rename constraint % on user_data.% to %: the name is already taken; resolve it and run again',
                r.conname, r.table_name, new_name;
        END;
        renamed := renamed + 1;
    END LOOP;
    RAISE NOTICE 'prefix_user_data_constraint_names: renamed %, kept %', renamed, kept;
END
$$;
