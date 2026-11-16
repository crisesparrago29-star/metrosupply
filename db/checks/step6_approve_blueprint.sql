-- Phase 3 Step 6 check: approve the blueprint draft.
-- Runs inside BEGIN ... ROLLBACK, so NOTHING is kept: stock stays 14/12/7.

BEGIN;

-- 1. Ana is staff: she must be refused.
SAVEPOINT before_ana;
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ana.staff');
ROLLBACK TO SAVEPOINT before_ana;

-- 2. Ben approves.
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ben.approver');

-- 3. Ben clicks again: same answer, nothing new reserved.
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ben.approver');

-- 4. What was reserved and what is backordered (base units).
SELECT l.line_no, l.raw_text, l.base_qty AS ordered, r.qty AS reserved,
       l.backorder_qty AS backordered, r.expires_at::date AS expires
FROM order_lines l
JOIN orders o ON o.id = l.order_id
LEFT JOIN reservations r ON r.order_line_id = l.id
WHERE o.po_number = 'PO-BLUEPRINT-1'
ORDER BY l.line_no;

-- 5. Stock after the approval.
SELECT sku, on_hand, reserved, available FROM available_stock ORDER BY sku;

-- 6. History for this order.
SELECT a.action, u.username, a.details
FROM audit_log a LEFT JOIN app_users u ON u.id = a.actor_user_id
WHERE a.entity = 'orders'
  AND a.entity_id = (SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1')
ORDER BY a.id;

ROLLBACK;

-- 7. After the rollback: stock is back to normal.
SELECT sku, available FROM available_stock ORDER BY sku;