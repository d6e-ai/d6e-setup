-- Migration: Enable pgvector extension and create embedding_config table
--
-- Enables the pgvector extension for vector similarity search and creates a
-- system table to track embedding configurations per workspace/table/column.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS embedding_config (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    workspace_id UUID NOT NULL REFERENCES workspace(id),
    table_name TEXT NOT NULL,
    source_column TEXT NOT NULL,
    embedding_column TEXT NOT NULL,
    model TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, table_name, source_column)
);
