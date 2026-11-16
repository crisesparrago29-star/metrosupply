-- Other ways an order can end. Rule: reserved stock is ALWAYS released.

-- Is this person allowed to make order decisions? Returns their id, or stops.
CREATE FUNCTION require_approver(p_username text) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_user_id bigint;
BEGIN
  SELECT u.id INTO v_user_id FROM app_users u
  WHERE u.username = lower(trim(p_username)) AND u.is_active
    AND u.role IN ('approver', 'admin');
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User % is not allowed to make order decisions', p_username;
  END IF;
  RETURN v_user_id;
END $$;

-- Free all ACTIVE reservations of one order. Returns how many were freed.
CREATE FUNCTION release_reservations(p_order_id bigint, p_new_status text DEFAULT 'released')
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  v_count int;
BEGIN
  IF p_new_status NOT IN ('released', 'expired') THEN
    RAISE EXCEPTION 'Reservations can only become released or expired, not %', p_new_status;
  END IF;
  UPDATE reservations r
  SET status = p_new_status, closed_at = now()
  FROM order_lines l
  WHERE l.id = r.order_line_id AND l.order_id = p_order_id AND r.status = 'active';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- An approver says NO to a draft. A reason is required.
CREATE FUNCTION reject_order(p_order_id bigint, p_username text, p_reason text)
RETURNS TABLE (result_order_id bigint, result_status text)
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id bigint := require_approver(p_username);
  v_status  text;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to reject an order';
  END IF;

  SELECT o.status INTO v_status FROM orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % does not exist', p_order_id;
  END IF;
  IF v_status = 'rejected' THEN                 -- already rejected: same answer
    RETURN QUERY SELECT p_order_id, v_status;
    RETURN;
  END IF;
  IF v_status NOT IN ('draft', 'needs_review') THEN
    RAISE EXCEPTION 'Order % is %; use cancel_order for approved orders', p_order_id, v_status;
  END IF;

  INSERT INTO approvals (order_id, decided_by, decision, note)
  VALUES (p_order_id, v_user_id, 'rejected', p_reason)
  ON CONFLICT (order_id, decided_by)
  DO UPDATE SET decision = 'rejected', note = EXCLUDED.note, decided_at = now();

  PERFORM release_reservations(p_order_id, 'released');
  UPDATE exceptions SET status = 'dismissed', resolved_by = v_user_id, resolved_at = now()
  WHERE order_id = p_order_id AND status = 'open';
  UPDATE orders SET status = 'rejected', updated_at = now() WHERE id = p_order_id;

  INSERT INTO audit_log (actor_user_id, action, entity, entity_id, details)
  VALUES (v_user_id, 'order.rejected', 'orders', p_order_id,
          jsonb_build_object('reason', p_reason));

  RETURN QUERY SELECT p_order_id, 'rejected'::text;
END $$;

-- Call off an order (even an approved one) and give its stock back.
CREATE FUNCTION cancel_order(p_order_id bigint, p_username text, p_reason text)
RETURNS TABLE (result_order_id bigint, result_status text, reservations_released int)
LANGUAGE plpgsql AS $$
DECLARE
  v_user_id  bigint := require_approver(p_username);
  v_status   text;
  v_released int;
BEGIN
  IF coalesce(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'A reason is required to cancel an order';
  END IF;

  SELECT o.status INTO v_status FROM orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % does not exist', p_order_id;
  END IF;
  IF v_status = 'cancelled' THEN                -- already cancelled: same answer
    RETURN QUERY SELECT p_order_id, v_status, 0;
    RETURN;
  END IF;
  IF v_status = 'rejected' THEN
    RAISE EXCEPTION 'Order % was rejected; there is nothing to cancel', p_order_id;
  END IF;

  v_released := release_reservations(p_order_id, 'released');
  UPDATE exceptions SET status = 'dismissed', resolved_by = v_user_id, resolved_at = now()
  WHERE order_id = p_order_id AND status = 'open';
  UPDATE orders SET status = 'cancelled', updated_at = now() WHERE id = p_order_id;

  INSERT INTO audit_log (actor_user_id, action, entity, entity_id, details)
  VALUES (v_user_id, 'order.cancelled', 'orders', p_order_id,
          jsonb_build_object('reason', p_reason, 'reservations_released', v_released));

  RETURN QUERY SELECT p_order_id, 'cancelled'::text, v_released;
END $$;

-- Free reservations that passed their expiry time. n8n will run this every hour.
CREATE FUNCTION expire_reservations()
RETURNS TABLE (expired_order_id bigint, reservations_expired int)
LANGUAGE plpgsql AS $$
DECLARE
  v_order_id bigint;
  v_count    int;
BEGIN
  FOR v_order_id IN
    SELECT DISTINCT l.order_id
    FROM reservations r JOIN order_lines l ON l.id = r.order_line_id
    WHERE r.status = 'active' AND r.expires_at <= now()
    ORDER BY l.order_id
  LOOP
    v_count := release_reservations(v_order_id, 'expired');
    INSERT INTO audit_log (action, entity, entity_id, details)
    VALUES ('reservations.expired', 'orders', v_order_id,
            jsonb_build_object('reservations_expired', v_count));
    expired_order_id     := v_order_id;
    reservations_expired := v_count;
    RETURN NEXT;
  END LOOP;
END $$;
