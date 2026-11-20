-- Bind inputs atomically with admission; only queued/running jobs hold files.
-- Admission and deletion/cleanup serialize on storage_file row locks.
-- Completion removes the hold logically (queries filter job status), without
-- requiring every completion/cancellation/error path to delete association rows.
CREATE TABLE IF NOT EXISTS frontend.intent_job_input_file (
    job_id UUID NOT NULL REFERENCES frontend.intent_job(id) ON DELETE CASCADE,
    storage_file_id UUID NOT NULL REFERENCES storage_file(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (job_id, storage_file_id)
);
CREATE INDEX IF NOT EXISTS idx_intent_job_input_file_storage_file
    ON frontend.intent_job_input_file(storage_file_id);
CREATE INDEX IF NOT EXISTS idx_storage_file_upload_age
    ON storage_file((metadata->>'source'), created_at, id);

-- Existing references are needed both for active holds and the bounded
-- post-completion cleanup grace. No permanent "ever started" flag is stored.
INSERT INTO frontend.intent_job_input_file (job_id, storage_file_id)
SELECT DISTINCT ij.id, sf.id
FROM frontend.intent_job ij
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(ij.request_payload->'inputFiles') = 'array'
         THEN ij.request_payload->'inputFiles' ELSE '[]'::jsonb END
) AS elem
JOIN storage_file sf ON sf.id::text = lower(elem->>'fileId')
    AND sf.workspace_id = ij.workspace_id
ON CONFLICT DO NOTHING;
