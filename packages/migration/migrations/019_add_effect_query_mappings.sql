-- Add query_mappings column to effect_version table
-- Enables GET effects to append query parameters from input mappings
ALTER TABLE public.effect_version
ADD COLUMN IF NOT EXISTS query_mappings JSONB NOT NULL DEFAULT '[]'::jsonb;
