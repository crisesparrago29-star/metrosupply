-- Step 8 check: log in AS n8n (app_n8n) and prove what it can and cannot do.
-- Everything is inside BEGIN ... ROLLBACK, so nothing is saved.

\echo '== Who am I? =='
SELECT current_user AS logged_in_as;

BEGIN;

\echo '== 1. ALLOWED: approve through the safe function =='
SELECT result_order_id, result_status, lines_reserved, lines_backordered
FROM approve_order(9, 'ben.approver');

\echo '== 2. ALLOWED: read stock (should now be lower) =='
SELECT sku, available FROM available_stock ORDER BY sku;

\echo '== 3. BLOCKED: write a reservation directly =='
SAVEPOINT s;
INSERT INTO reservations (order_line_id, product_id, qty, expires_at)
VALUES (1, 1, 5, now() + interval '1 day');
ROLLBACK TO SAVEPOINT s;

\echo '== 4. BLOCKED: change an order status directly =='
SAVEPOINT s;
UPDATE orders SET status = 'approved' WHERE id = 9;
ROLLBACK TO SAVEPOINT s;

\echo '== 5. BLOCKED: use a helper function directly =='
SAVEPOINT s;
SELECT release_reservations(9);
ROLLBACK TO SAVEPOINT s;

\echo '== 6. BLOCKED: erase stock history =='
SAVEPOINT s;
DELETE FROM stock_movements;
ROLLBACK TO SAVEPOINT s;

ROLLBACK;

\echo '== After ROLLBACK: stock back to normal =='
SELECT sku, available FROM available_stock ORDER BY sku;