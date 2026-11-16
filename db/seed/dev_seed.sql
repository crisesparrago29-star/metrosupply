-- FICTIONAL sample data for local practice. NEVER run on a real client database.
-- Blueprint example: available = 14 jugs hand soap / 12 cartons tissue / 7 boxes garbage bags.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM products) THEN
    RAISE EXCEPTION 'Seed already loaded: products table is not empty';
  END IF;
END $$;

INSERT INTO units (code, name) VALUES
  ('jug', 'Jug'), ('roll', 'Roll'), ('pack', 'Pack'), ('btl', 'Bottle'),
  ('ctn', 'Carton'), ('box', 'Box')
ON CONFLICT (code) DO NOTHING;

INSERT INTO products (sku, name, base_unit) VALUES
  ('HS-5L', 'Hand soap 5L',          'jug'),
  ('JT-12', 'Jumbo tissue roll',     'roll'),
  ('GB-XL', 'Garbage bags XL',       'pack'),
  ('DS-1L', 'Dishwashing liquid 1L', 'btl');

-- How many base units are in each unit customers order in.
INSERT INTO unit_conversions (product_id, unit, base_qty)
SELECT p.id, v.unit, v.base_qty
FROM (VALUES
  ('HS-5L', 'jug',  1), ('HS-5L', 'ctn', 4),
  ('JT-12', 'roll', 1), ('JT-12', 'ctn', 12),
  ('GB-XL', 'pack', 1), ('GB-XL', 'box', 10),
  ('DS-1L', 'btl',  1), ('DS-1L', 'ctn', 12)
) AS v(sku, unit, base_qty)
JOIN products p ON p.sku = v.sku;

-- Other names customers use.
INSERT INTO product_aliases (product_id, alias)
SELECT p.id, v.alias
FROM (VALUES
  ('HS-5L', 'hand soap'), ('HS-5L', 'hand soap 5L'), ('HS-5L', 'liquid hand soap'),
  ('JT-12', 'jumbo tissue'), ('JT-12', 'tissue'), ('JT-12', 'JT'),
  ('GB-XL', 'garbage bags'), ('GB-XL', 'trash bags XL'),
  ('DS-1L', 'dish soap')
) AS v(sku, alias)
JOIN products p ON p.sku = v.sku;

INSERT INTO customers (code, name) VALUES
  ('CLEANPRO', 'CleanPro Facility Services (fictional)'),
  ('BAYVIEW',  'Bayview Office Tower (fictional)');

INSERT INTO app_users (username, full_name, role) VALUES
  ('ana.staff',      'Ana Reyes (fictional)',   'staff'),
  ('ben.approver',   'Ben Cruz (fictional)',    'approver'),
  ('carla.approver', 'Carla Santos (fictional)', 'approver'),
  ('admin',          'MetroSupply Admin',        'admin');

-- Standard prices per BASE unit, VAT included.
INSERT INTO product_prices (product_id, unit_price, valid_from)
SELECT p.id, v.price, DATE '2026-11-01'
FROM (VALUES
  ('HS-5L', 450.00), ('JT-12', 38.00), ('GB-XL', 65.00), ('DS-1L', 85.00)
) AS v(sku, price)
JOIN products p ON p.sku = v.sku;

-- One special customer price: CleanPro pays 420 per jug until 2027-01-01.
INSERT INTO customer_prices (customer_id, product_id, unit_price, valid_from, valid_to)
SELECT c.id, p.id, 420.00, DATE '2026-11-01', DATE '2027-01-01'
FROM customers c, products p
WHERE c.code = 'CLEANPRO' AND p.sku = 'HS-5L';

-- Stock ledger: gives 14 jugs / 12 cartons (144 rolls) / 7 boxes (70 packs).
-- Dishwashing liquid has no stock on purpose (for testing shortages later).
INSERT INTO stock_movements (product_id, qty, reason, note)
SELECT p.id, v.qty, v.reason, v.note
FROM (VALUES
  ('HS-5L',  20, 'opening',  'Opening count'),
  ('HS-5L',  -6, 'delivery', 'Earlier delivery'),
  ('JT-12', 144, 'opening',  'Opening count: 12 cartons'),
  ('GB-XL',  70, 'opening',  'Opening count: 7 boxes')
) AS v(sku, qty, reason, note)
JOIN products p ON p.sku = v.sku;
