-- Helpers used by create_draft_order (Step 5).
-- Each returns NULL when it can't answer, so the caller can flag a problem.

-- Which product did the customer mean? Exact SKU first, then an alias.
CREATE FUNCTION find_product(p_text text) RETURNS bigint
LANGUAGE sql STABLE AS $$
  SELECT product_id FROM (
    SELECT id AS product_id, 1 AS priority
    FROM products
    WHERE sku = upper(trim(p_text)) AND is_active
    UNION ALL
    SELECT a.product_id, 2 AS priority
    FROM product_aliases a
    JOIN products p ON p.id = a.product_id
    WHERE lower(a.alias) = lower(trim(p_text)) AND p.is_active
  ) matches
  ORDER BY priority
  LIMIT 1
$$;

-- Convert a quantity in any known unit to the product's base unit.
-- Accepts simple plurals: 'ctns' -> 'ctn', 'boxes' -> 'box', 'jugs' -> 'jug'.
CREATE FUNCTION to_base_qty(p_product_id bigint, p_qty numeric, p_unit text) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT p_qty * c.base_qty
  FROM unit_conversions c
  WHERE c.product_id = p_product_id
    AND c.unit IN (lower(trim(p_unit)),
                   regexp_replace(lower(trim(p_unit)), 'es$', ''),
                   regexp_replace(lower(trim(p_unit)), 's$', ''))
  LIMIT 1
$$;

-- Price per BASE unit (VAT included) for this customer on this date.
-- A customer's special price wins; otherwise the standard price.
CREATE FUNCTION price_for(p_customer_id bigint, p_product_id bigint,
                          p_on date DEFAULT current_date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT unit_price FROM customer_prices
      WHERE customer_id = p_customer_id AND product_id = p_product_id
        AND daterange(valid_from, valid_to, '[)') @> p_on),
    (SELECT unit_price FROM product_prices
      WHERE product_id = p_product_id
        AND daterange(valid_from, valid_to, '[)') @> p_on)
  )
$$;