-- Business settings the functions read. Change a rule by updating one row.

CREATE TABLE settings (
  key         text PRIMARY KEY,
  value       text NOT NULL,
  description text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO settings (key, value, description) VALUES
  ('reservation_ttl_days',          '7',     'Days an approved reservation stays active before it expires'),
  ('expiry_warning_days',           '2',     'Days before expiry to send a warning'),
  ('allow_partial',                 'true',  'Reserve what is available and backorder the rest'),
  ('second_approver_threshold_php', '50000', 'Orders above this total (VAT included) need two different approvers. PLACEHOLDER: owner decision pending');

-- Read one setting by name.
CREATE FUNCTION get_setting(p_key text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT value FROM settings WHERE key = p_key
$$;

GRANT SELECT ON settings TO app_n8n;
