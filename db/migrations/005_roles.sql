-- Least privilege: a separate login for n8n that can only read (for now).
-- Its password is set from .env, never stored in Git.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_n8n') THEN
    CREATE ROLE app_n8n LOGIN;
  END IF;
END $$;

GRANT CONNECT ON DATABASE metrosupply TO app_n8n;
GRANT USAGE ON SCHEMA public TO app_n8n;

-- Read-only access to what n8n needs to look at.
GRANT SELECT ON
  units, products, product_aliases, unit_conversions,
  customers, product_prices, customer_prices,
  available_stock, intake_events, orders, order_lines, exceptions
TO app_n8n;

-- Deliberately NOT granted: any INSERT, UPDATE or DELETE.
-- In Phase 3, n8n gets permission to run the safe functions only.
