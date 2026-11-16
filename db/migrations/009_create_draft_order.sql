-- Build a DRAFT order from a customer message. Flags problems, reserves NOTHING.
-- p_lines example: [{"product":"hand soap","qty":12,"unit":"jugs"}, ...]

CREATE FUNCTION create_draft_order(p_event_id bigint, p_customer_code text,
                                   p_po_number text, p_lines jsonb)
RETURNS TABLE (draft_order_id bigint, draft_status text, draft_total numeric, problems int)
LANGUAGE plpgsql AS $$
DECLARE
  v_customer_id bigint;
  v_order_id    bigint;
  v_line        jsonb;
  v_line_no     int;
  v_text        text;
  v_qty         numeric;
  v_unit_in     text;
  v_product_id  bigint;
  v_unit        text;
  v_per_unit    numeric;
  v_base_qty    numeric;
  v_price       numeric;
  v_available   numeric;
  v_line_id     bigint;
  v_problems    int := 0;
BEGIN
  -- 1. Same message already turned into an order? Return that order.
  SELECT o.id INTO v_order_id FROM orders o WHERE o.intake_event_id = p_event_id;
  IF v_order_id IS NOT NULL THEN
    RETURN QUERY
      SELECT o.id, o.status, o.total_amount,
             (SELECT count(*)::int FROM exceptions e WHERE e.order_id = o.id)
      FROM orders o WHERE o.id = v_order_id;
    RETURN;
  END IF;

  -- 2. Basic checks.
  SELECT c.id INTO v_customer_id FROM customers c
  WHERE c.code = upper(trim(p_customer_code)) AND c.is_active;
  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'Unknown customer: %', p_customer_code;
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'An order needs at least one line';
  END IF;

  IF p_po_number IS NOT NULL AND EXISTS (
       SELECT 1 FROM orders o WHERE o.customer_id = v_customer_id AND o.po_number = p_po_number) THEN
    RAISE EXCEPTION 'Duplicate PO % for customer %', p_po_number, p_customer_code;
  END IF;

  -- 3. Create the order, then each line.
  INSERT INTO orders (intake_event_id, customer_id, po_number)
  VALUES (p_event_id, v_customer_id, p_po_number)
  RETURNING id INTO v_order_id;

  FOR v_line, v_line_no IN
    SELECT value, ordinality FROM jsonb_array_elements(p_lines) WITH ORDINALITY
  LOOP
    v_text    := v_line->>'product';
    v_qty     := (v_line->>'qty')::numeric;
    v_unit_in := v_line->>'unit';
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'Line %: quantity must be more than 0', v_line_no;
    END IF;

    v_product_id := find_product(v_text);
    v_unit := NULL; v_per_unit := NULL; v_base_qty := NULL; v_price := NULL;

    IF v_product_id IS NOT NULL THEN
      SELECT c.unit, c.base_qty INTO v_unit, v_per_unit
      FROM unit_conversions c
      WHERE c.product_id = v_product_id
        AND c.unit IN (lower(trim(v_unit_in)),
                       regexp_replace(lower(trim(v_unit_in)), 'es$', ''),
                       regexp_replace(lower(trim(v_unit_in)), 's$', ''))
      LIMIT 1;
      IF v_unit IS NOT NULL THEN
        v_base_qty := v_qty * v_per_unit;
        v_price    := price_for(v_customer_id, v_product_id);
      END IF;
    END IF;

    INSERT INTO order_lines (order_id, line_no, raw_text, product_id, qty, unit,
                             base_qty, unit_price, line_total)
    VALUES (v_order_id, v_line_no, concat_ws(' ', v_line->>'qty', v_unit_in, v_text),
            v_product_id, v_qty, v_unit, v_base_qty, v_price, round(v_base_qty * v_price, 2))
    RETURNING id INTO v_line_id;

    -- 4. Flag problems for a person. Never guess.
    IF v_product_id IS NULL THEN
      INSERT INTO exceptions (order_id, order_line_id, kind, message)
      VALUES (v_order_id, v_line_id, 'unknown_product',
              format('Line %s: unknown product "%s"', v_line_no, v_text));
      v_problems := v_problems + 1;
    ELSIF v_unit IS NULL THEN
      INSERT INTO exceptions (order_id, order_line_id, kind, message)
      VALUES (v_order_id, v_line_id, 'unknown_unit',
              format('Line %s: unknown unit "%s" for %s', v_line_no, v_unit_in, v_text));
      v_problems := v_problems + 1;
    ELSE
      IF v_price IS NULL THEN
        INSERT INTO exceptions (order_id, order_line_id, kind, message)
        VALUES (v_order_id, v_line_id, 'no_price',
                format('Line %s: no price today for %s', v_line_no, v_text));
        v_problems := v_problems + 1;
      END IF;

      SELECT a.available INTO v_available FROM available_stock a WHERE a.product_id = v_product_id;
      IF v_base_qty > v_available THEN
        INSERT INTO exceptions (order_id, order_line_id, kind, message)
        VALUES (v_order_id, v_line_id, 'shortage',
                format('Line %s: short by %s %s (requested %s, available %s)', v_line_no,
                       trim_scale((v_base_qty - v_available) / v_per_unit), v_unit,
                       trim_scale(v_qty), trim_scale(v_available / v_per_unit)));
        v_problems := v_problems + 1;
      END IF;
    END IF;
  END LOOP;

  -- 5. Total and status.
  UPDATE orders o
  SET total_amount = coalesce((SELECT sum(l.line_total) FROM order_lines l
                               WHERE l.order_id = v_order_id), 0),
      status       = CASE WHEN v_problems > 0 THEN 'needs_review' ELSE 'draft' END,
      updated_at   = now()
  WHERE o.id = v_order_id;

  -- 6. History.
  INSERT INTO audit_log (action, entity, entity_id, details)
  VALUES ('order.drafted', 'orders', v_order_id,
          jsonb_build_object('problems', v_problems, 'lines', jsonb_array_length(p_lines)));

  RETURN QUERY
    SELECT o.id, o.status, o.total_amount, v_problems FROM orders o WHERE o.id = v_order_id;
END $$;
