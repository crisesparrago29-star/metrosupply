-- Approve an order: check the approver, lock stock in SKU order,
-- reserve what is available, backorder the rest, write history.

CREATE FUNCTION approve_order(p_order_id bigint, p_username text)
RETURNS TABLE (result_order_id bigint, result_status text, approvals_have int,
               approvals_needed int, lines_reserved int, lines_backordered int)
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id    bigint;
  v_order      orders%ROWTYPE;
  v_needed     int;
  v_have       int;
  v_line       record;
  v_available  numeric;
  v_reserve    numeric;
  v_ttl_days   int     := get_setting('reservation_ttl_days')::int;
  v_partial_ok boolean := get_setting('allow_partial')::boolean;
  v_reserved   int := 0;
  v_backorders int := 0;
BEGIN
  -- 1. Only active approvers or admins may approve.
  SELECT u.id INTO v_user_id FROM app_users u
  WHERE u.username = lower(trim(p_username)) AND u.is_active
    AND u.role IN ('approver', 'admin');
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User % is not allowed to approve orders', p_username;
  END IF;

  -- 2. Lock the order so two people can't change it at the same moment.
  SELECT * INTO v_order FROM orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % does not exist', p_order_id;
  END IF;
  IF v_order.status IN ('rejected', 'cancelled') THEN
    RAISE EXCEPTION 'Order % is %, it cannot be approved', p_order_id, v_order.status;
  END IF;

  v_needed := CASE WHEN v_order.total_amount
                        > get_setting('second_approver_threshold_php')::numeric
                   THEN 2 ELSE 1 END;

  -- 3. Already approved? Return the current state (safe to click twice).
  IF v_order.status IN ('approved', 'partially_reserved') THEN
    RETURN QUERY SELECT v_order.id, v_order.status,
      (SELECT count(*)::int FROM approvals a
        WHERE a.order_id = v_order.id AND a.decision = 'approved'),
      v_needed,
      (SELECT count(DISTINCT r.order_line_id)::int FROM reservations r
         JOIN order_lines l ON l.id = r.order_line_id WHERE l.order_id = v_order.id),
      (SELECT count(*)::int FROM order_lines l
        WHERE l.order_id = v_order.id AND l.backorder_qty > 0);
    RETURN;
  END IF;

  -- 4. Problems other than a shortage must be fixed first.
  IF EXISTS (SELECT 1 FROM exceptions e
             WHERE e.order_id = p_order_id AND e.status = 'open' AND e.kind <> 'shortage') THEN
    RAISE EXCEPTION 'Order % has unresolved problems; fix them before approving', p_order_id;
  END IF;

  -- 5. Record this person's approval (counts once per person).
  INSERT INTO approvals (order_id, decided_by, decision)
  VALUES (p_order_id, v_user_id, 'approved')
  ON CONFLICT (order_id, decided_by) DO NOTHING;

  SELECT count(*)::int INTO v_have FROM approvals a
  WHERE a.order_id = p_order_id AND a.decision = 'approved';

  IF v_have < v_needed THEN
    INSERT INTO audit_log (actor_user_id, action, entity, entity_id, details)
    VALUES (v_user_id, 'order.approval_recorded', 'orders', p_order_id,
            jsonb_build_object('have', v_have, 'needed', v_needed));
    RETURN QUERY SELECT v_order.id, v_order.status, v_have, v_needed, 0, 0;
    RETURN;
  END IF;

  -- 6. Lock every product on this order, ALWAYS in SKU order (prevents deadlocks).
  PERFORM 1 FROM products p
  WHERE p.id IN (SELECT l.product_id FROM order_lines l WHERE l.order_id = p_order_id)
  ORDER BY p.sku
  FOR UPDATE;

  -- 7. Reserve what is available; the rest becomes a backorder.
  FOR v_line IN
    SELECT l.id, l.product_id, l.base_qty FROM order_lines l
    WHERE l.order_id = p_order_id AND l.product_id IS NOT NULL AND l.base_qty IS NOT NULL
    ORDER BY l.line_no
  LOOP
    SELECT a.available INTO v_available FROM available_stock a
    WHERE a.product_id = v_line.product_id;
    v_reserve := least(v_line.base_qty, greatest(coalesce(v_available, 0), 0));

    IF v_reserve < v_line.base_qty AND NOT v_partial_ok THEN
      RAISE EXCEPTION 'Not enough stock for line % and partial orders are switched off', v_line.id;
    END IF;

    IF v_reserve > 0 THEN
      INSERT INTO reservations (order_line_id, product_id, qty, expires_at)
      VALUES (v_line.id, v_line.product_id, v_reserve,
              now() + make_interval(days => v_ttl_days));
      v_reserved := v_reserved + 1;
    END IF;

    UPDATE order_lines SET backorder_qty = v_line.base_qty - v_reserve WHERE id = v_line.id;
    IF v_reserve < v_line.base_qty THEN
      v_backorders := v_backorders + 1;
    END IF;
  END LOOP;

  -- 8. Shortages are now handled as backorders; set the status; write history.
  UPDATE exceptions SET status = 'resolved', resolved_by = v_user_id, resolved_at = now()
  WHERE order_id = p_order_id AND kind = 'shortage' AND status = 'open';

  UPDATE orders
  SET status = CASE WHEN v_backorders > 0 THEN 'partially_reserved' ELSE 'approved' END,
      updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO audit_log (actor_user_id, action, entity, entity_id, details)
  VALUES (v_user_id, 'order.approved', 'orders', p_order_id,
          jsonb_build_object('lines_reserved', v_reserved,
                             'lines_backordered', v_backorders, 'approvals', v_have));

  RETURN QUERY SELECT o.id, o.status, v_have, v_needed, v_reserved, v_backorders
               FROM orders o WHERE o.id = p_order_id;
END $$;
