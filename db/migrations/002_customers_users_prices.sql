-- Who is involved, and what things cost.
-- All prices are in PHP, per base unit, and INCLUDE 12% VAT.

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- needed for the "no overlapping periods" rule

CREATE TABLE customers (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code       text NOT NULL UNIQUE CHECK (code <> '' AND code = upper(code)),
  name       text NOT NULL CHECK (name <> ''),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_users (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username         text NOT NULL UNIQUE CHECK (username <> '' AND username = lower(username)),
  full_name        text NOT NULL,
  role             text NOT NULL CHECK (role IN ('staff', 'approver', 'admin')),
  telegram_user_id bigint UNIQUE,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- Standard price for everyone, valid for a period.
CREATE TABLE product_prices (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id bigint NOT NULL REFERENCES products(id),
  unit_price numeric(12,2) NOT NULL CHECK (unit_price > 0),
  valid_from date NOT NULL,
  valid_to   date,                                   -- NULL = no end date yet
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  EXCLUDE USING gist (product_id WITH =,
                      daterange(valid_from, valid_to, '[)') WITH &&)
);

-- Special price for one customer, valid for a period.
CREATE TABLE customer_prices (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers(id),
  product_id  bigint NOT NULL REFERENCES products(id),
  unit_price  numeric(12,2) NOT NULL CHECK (unit_price > 0),
  valid_from  date NOT NULL,
  valid_to    date,
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  EXCLUDE USING gist (customer_id WITH =, product_id WITH =,
                      daterange(valid_from, valid_to, '[)') WITH &&)
);
