-- Migration: Split workspace.custom_prompt into individual prompt rules
-- Creates frontend.workspace_prompt_rule table and migrates existing data
-- by splitting on Markdown headings (lines starting with #).

CREATE TABLE IF NOT EXISTS frontend.workspace_prompt_rule (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workspace_prompt_rule_workspace_sort
    ON frontend.workspace_prompt_rule(workspace_id, sort_order);

-- Migrate existing custom_prompt data by splitting on Markdown headings.
-- Each heading (line starting with #) begins a new rule.
-- Content before the first heading becomes rule 0.
DO $$
DECLARE
    ws RECORD;
    lines TEXT[];
    current_chunk TEXT := '';
    sort_idx INTEGER := 0;
    i INTEGER;
    line TEXT;
BEGIN
    FOR ws IN
        SELECT id, custom_prompt
        FROM workspace
        WHERE custom_prompt IS NOT NULL
          AND TRIM(custom_prompt) <> ''
          AND deleted_at IS NULL
    LOOP
        lines := string_to_array(ws.custom_prompt, E'\n');
        current_chunk := '';
        sort_idx := 0;

        FOR i IN 1..array_length(lines, 1) LOOP
            line := lines[i];

            -- If line starts with '#', flush previous chunk and start new one
            IF line ~ '^#{1,6}\s' AND TRIM(current_chunk) <> '' THEN
                INSERT INTO frontend.workspace_prompt_rule (workspace_id, content, sort_order)
                VALUES (ws.id, TRIM(current_chunk), sort_idx);
                sort_idx := sort_idx + 1;
                current_chunk := '';
            END IF;

            current_chunk := current_chunk || line || E'\n';
        END LOOP;

        -- Flush remaining chunk
        IF TRIM(current_chunk) <> '' THEN
            INSERT INTO frontend.workspace_prompt_rule (workspace_id, content, sort_order)
            VALUES (ws.id, TRIM(current_chunk), sort_idx);
        END IF;
    END LOOP;
END $$;
