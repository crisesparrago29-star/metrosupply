-- Phase 3 Step 7 check: cancel, reject and expire. Every part is rolled back.

-- ===== A. Approve, then CANCEL: stock must come back =====
BEGIN;
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ben.approver');
SELECT 'A: after approve' AS step, sku, available FROM available_stock ORDER BY sku;
SELECT * FROM cancel_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'),
                           'carla.approver', 'Customer called to cancel');
SELECT 'A: after cancel' AS step, sku, available FROM available_stock ORDER BY sku;
SELECT 'A: reservations' AS step, r.status, count(*)
FROM reservations r JOIN order_lines l ON l.id = r.order_line_id
JOIN orders o ON o.id = l.order_id
WHERE o.po_number = 'PO-BLUEPRINT-1' GROUP BY r.status;
ROLLBACK;

-- ===== B. REJECT the draft =====
BEGIN;
SAVEPOINT before_ana;
SELECT * FROM reject_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'),
                           'ana.staff', 'I do not like it');
ROLLBACK TO SAVEPOINT before_ana;
SELECT * FROM reject_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'),
                           'carla.approver', 'Customer sent the wrong PO');
SAVEPOINT before_ben;
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ben.approver');
ROLLBACK TO SAVEPOINT before_ben;
SELECT 'B: history' AS step, a.action, u.username, a.details
FROM audit_log a LEFT JOIN app_users u ON u.id = a.actor_user_id
WHERE a.entity = 'orders'
  AND a.entity_id = (SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1')
ORDER BY a.id;
ROLLBACK;

-- ===== C. Approve, pretend 8 days pass, then EXPIRE =====
BEGIN;
SELECT * FROM approve_order((SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'), 'ben.approver');
UPDATE reservations SET expires_at = now() - interval '1 day' WHERE status = 'active';
SELECT * FROM expire_reservations();
SELECT 'C: after expiry' AS step, sku, available FROM available_stock ORDER BY sku;
ROLLBACK;

-- ===== After everything: stock is unchanged =====
SELECT 'Final' AS step, sku, available FROM available_stock ORDER BY sku;