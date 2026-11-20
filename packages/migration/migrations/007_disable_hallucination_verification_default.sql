-- Change default value of hallucination_verification_enabled to false
ALTER TABLE frontend.user_workspace_settings
    ALTER COLUMN hallucination_verification_enabled SET DEFAULT false;
