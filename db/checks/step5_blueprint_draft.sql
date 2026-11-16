-- Phase 3 Step 5 check: the blueprint order as a draft.
-- Creates a real draft for BAYVIEW (kept for Step 6). Reserves nothing.
-- Safe to run again: the same message returns the same order.

SELECT * FROM create_draft_order(
  (SELECT event_id FROM record_intake_event('telegram', 'demo-blueprint',
     '12 jugs hand soap, 10 ctns jumbo tissue, 10 boxes garbage bags')),
  'BAYVIEW', 'PO-BLUEPRINT-1',
  '[{"product":"hand soap",    "qty":12, "unit":"jugs"},
    {"product":"jumbo tissue", "qty":10, "unit":"ctns"},
    {"product":"garbage bags", "qty":10, "unit":"boxes"}]');

-- The lines
SELECT l.line_no, l.raw_text, l.unit, l.base_qty, l.unit_price, l.line_total
FROM order_lines l JOIN orders o ON o.id = l.order_id
WHERE o.po_number = 'PO-BLUEPRINT-1'
ORDER BY l.line_no;

-- The problems
SELECT e.kind, e.message
FROM exceptions e JOIN orders o ON o.id = e.order_id
WHERE o.po_number = 'PO-BLUEPRINT-1';

-- Nothing reserved
SELECT count(*) AS reservations FROM reservations;