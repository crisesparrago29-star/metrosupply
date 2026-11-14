-- How much we have: the stock ledger, reservations and the available-stock view.
-- All quantities are in each product's BASE unit.

CREATE TABLE stock_movements (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id bigint NOT NULL REFERENCES products(id),
  qty        numeric(12,4) NOT NULL CHECK (qty <> 0),   -- plus = in, minus = out
  reason     text NOT NULL CHECK (reason IN
               ('opening', 'receipt', 'delivery', 'return', 'adjustment')),
  note       text,
  created_by bigint REFERENCES app_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX stock_movements_product_idx ON stock_movements (product_id);

-- Guard: ledger rows can never be changed or deleted.
CREATE FUNCTION block_ledger_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only: add a correcting movement instead';
END $$;

CREATE TRIGGER stock_movements_no_update_delete
  BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION block_ledger_change();

CREATE TRIGGER stock_movements_no_truncate
  BEFORE TRUNCATE ON stock_movements
  FOR EACH STATEMENT EXECUTE FUNCTION block_ledger_change();

-- Stock set aside for approved orders.
CREATE TABLE reservations (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_line_id bigint NOT NULL,          -- the link to order_lines is added in Step 6
  product_id    bigint NOT NULL REFERENCES products(id),
  qty           numeric(12,4) NOT NULL CHECK (qty > 0),
  status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'released', 'fulfilled', 'expired')),
  expires_at    timestamptz NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz
);
CREATE INDEX reservations_active_idx ON reservations (product_id) WHERE status = 'active';

-- On hand = sum of movements. Available = on hand - active reservations.
CREATE VIEW available_stock AS
SELECT p.id   AS product_id,
       p.sku,
       p.name,
       p.base_unit,
       COALESCE(m.on_hand, 0)                          AS on_hand,
       COALESCE(r.reserved, 0)                         AS reserved,
       COALESCE(m.on_hand, 0) - COALESCE(r.reserved, 0) AS available
FROM products p
LEFT JOIN (SELECT product_id, sum(qty) AS on_hand
           FROM stock_movements GROUP BY product_id) m ON m.product_id = p.id
LEFT JOIN (SELECT product_id, sum(qty) AS reserved
           FROM reservations WHERE status = 'active' GROUP BY product_id) r ON r.product_id = p.id;
