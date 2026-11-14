-- What we sell: units, products, other names, and unit conversions.

CREATE TABLE units (
  code text PRIMARY KEY,                 -- short code, e.g. 'jug', 'ctn'
  name text NOT NULL                     -- full name, e.g. 'Carton'
);

CREATE TABLE products (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku        text NOT NULL UNIQUE CHECK (sku <> '' AND sku = upper(sku)),
  name       text NOT NULL CHECK (name <> ''),
  base_unit  text NOT NULL REFERENCES units(code),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE product_aliases (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id bigint NOT NULL REFERENCES products(id),
  alias      text NOT NULL CHECK (alias <> '')
);
-- The same alias can't point to two products (ignoring capital letters).
CREATE UNIQUE INDEX product_aliases_alias_uq ON product_aliases (lower(alias));

CREATE TABLE unit_conversions (
  product_id bigint NOT NULL REFERENCES products(id),
  unit       text   NOT NULL REFERENCES units(code),
  base_qty   numeric(12,4) NOT NULL CHECK (base_qty > 0),  -- e.g. 1 ctn = 4 jugs
  PRIMARY KEY (product_id, unit)
);
