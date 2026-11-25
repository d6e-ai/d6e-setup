-- What kind of line an outbound call dialed: 'landline', 'ip' (050), 'mobile' or 'other'. It is
-- decided from the number when the call is placed, so the call can be counted at the price of its
-- kind; the number itself is not kept here (and a call row drops its number soon after the call).
-- A request that was never dialed, and a request placed before this column, has none.
ALTER TABLE voice_live_call_request ADD COLUMN IF NOT EXISTS destination_kind TEXT
    CHECK (destination_kind IN ('landline', 'ip', 'mobile', 'other'));
