CREATE TABLE hello_test (
  id          serial PRIMARY KEY,
  note        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
