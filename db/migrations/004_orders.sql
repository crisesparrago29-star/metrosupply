-- What happened: intake events, orders, lines, exceptions, approvals, audit log.

-- The original customer message, saved exactly as received.
CREATE TABLE intake_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source      text NOT NULL CHECK (source IN ('form', 'telegram', 'email', 'manual')),
  source_ref  text NOT NULL,          -- e.g. Telegram's message ID
  raw_text    text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, source_ref)         -- the same message can't be saved twice
);

CREATE TABLE orders (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  intake_event_id bigint REFERENCES intake_events(id),
  customer_id     bigint NOT NULL REFERENCES customers(id),
  po_number       text,               -- the customer's purchase order number, if any
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN
                    ('draft', 'needs_review', 'approved', 'partially_reserved',
                     'rejected', 'cancelled')),
  total_amount    numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),  -- VAT included
  vat_amount      numeric(12,2) GENERATED ALWAYS AS (round(total_amount * 12 / 112, 2)) STORED,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_id, po_number)     -- same customer + same PO = duplicate
);

CREATE TABLE order_lines (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id      bigint NOT NULL REFERENCES orders(id),
  line_no       int NOT NULL CHECK (line_no > 0),
  raw_text      text,                 -- what the customer wrote for this line
  product_id    bigint REFERENCES products(id),   -- empty until the product is matched
  qty           numeric(12,4) NOT NULL CHECK (qty > 0),
  unit          text REFERENCES units(code),
  base_qty      numeric(12,4) CHECK (base_qty > 0),        -- qty converted to base units
  unit_price    numeric(12,2) CHECK (unit_price > 0),      -- per base unit, VAT included
  line_total    numeric(12,2) CHECK (line_total >= 0),
  backorder_qty numeric(12,4) NOT NULL DEFAULT 0 CHECK (backorder_qty >= 0),
  UNIQUE (order_id, line_no)
);

-- Now that order_lines exists, link reservations to it (promised in Step 5).
ALTER TABLE reservations
  ADD CONSTRAINT reservations_order_line_fk
  FOREIGN KEY (order_line_id) REFERENCES order_lines(id);

-- Problems that need a person.
CREATE TABLE exceptions (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id      bigint NOT NULL REFERENCES orders(id),
  order_line_id bigint REFERENCES order_lines(id),
  kind          text NOT NULL CHECK (kind IN
                  ('unknown_product', 'unknown_unit', 'no_price', 'shortage', 'other')),
  message       text NOT NULL,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
  resolved_by   bigint REFERENCES app_users(id),
  resolved_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Who approved or rejected each order. One decision per person per order.
CREATE TABLE approvals (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id   bigint NOT NULL REFERENCES orders(id),
  decided_by bigint NOT NULL REFERENCES app_users(id),
  decision   text NOT NULL CHECK (decision IN ('approved', 'rejected')),
  note       text,
  decided_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id, decided_by)
);

-- History of every important action. Append-only, like the stock ledger.
CREATE TABLE audit_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  actor_user_id bigint REFERENCES app_users(id),
  action        text NOT NULL,        -- e.g. 'order.approved'
  entity        text NOT NULL,        -- e.g. 'orders'
  entity_id     bigint,
  details       jsonb NOT NULL DEFAULT '{}'
);

CREATE FUNCTION block_append_only_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: add a new row instead', TG_TABLE_NAME;
END $$;

CREATE TRIGGER audit_log_no_update_delete
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION block_append_only_change();

CREATE TRIGGER audit_log_no_truncate
  BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION block_append_only_change();
