-- File embedding tables for multimodal vector search via Gemini Embedding 2.
-- Requires pgvector extension (enabled by migration 002).

CREATE TABLE IF NOT EXISTS file_embedding (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    file_id UUID NOT NULL REFERENCES storage_file(id),
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    embedding vector,
    status TEXT NOT NULL DEFAULT 'pending',
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, file_id)
);

CREATE TABLE IF NOT EXISTS file_embedding_chunk (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    file_embedding_id UUID NOT NULL REFERENCES file_embedding(id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    chunk_type TEXT NOT NULL,
    chunk_label TEXT,
    embedding vector,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (file_embedding_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_file_embedding_workspace_status ON file_embedding (workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_file_embedding_file_id ON file_embedding (file_id);
