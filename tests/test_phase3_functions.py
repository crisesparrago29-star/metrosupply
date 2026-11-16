"""Phase 3 tests: the stock-safety functions.

Every test runs inside a transaction that is rolled back afterwards
(see conftest.py), so the real database is never changed.
Most tests use the blueprint order (PO-BLUEPRINT-1) from Step 5:
12 jugs soap, 10 ctns tissue, 10 boxes garbage bags, but only 7 boxes in stock.
"""
import psycopg
import pytest

START_STOCK = {"DS-1L": 0, "GB-XL": 70, "HS-5L": 14, "JT-12": 144}
AFTER_APPROVE = {"DS-1L": 0, "GB-XL": 0, "HS-5L": 2, "JT-12": 24}


# ---------- small helpers ----------

def blueprint_id(conn):
    return conn.execute(
        "SELECT id FROM orders WHERE po_number = 'PO-BLUEPRINT-1'").fetchone()[0]


def stock(conn):
    return dict(conn.execute("SELECT sku, available FROM available_stock").fetchall())


def active_reservations(conn, order_id):
    return conn.execute(
        """SELECT l.line_no, r.qty FROM reservations r
           JOIN order_lines l ON l.id = r.order_line_id
           WHERE l.order_id = %s AND r.status = 'active'
           ORDER BY l.line_no""", (order_id,)).fetchall()


def approve(conn, order_id, username):
    return conn.execute(
        "SELECT result_status, approvals_have, approvals_needed FROM approve_order(%s, %s)",
        (order_id, username)).fetchone()


# ---------- intake ----------

def test_same_message_saved_once(app_db):
    rows = [app_db.execute(
        "SELECT event_id, is_new FROM record_intake_event('telegram', 'test-dup-1', '5 jugs hand soap')"
    ).fetchone() for _ in range(5)]
    assert len({r[0] for r in rows}) == 1
    assert [r[1] for r in rows] == [True, False, False, False, False]


# ---------- draft ----------

def test_blueprint_draft_reserves_nothing(db):
    oid = blueprint_id(db)
    status, total = db.execute(
        "SELECT status, total_amount FROM orders WHERE id = %s", (oid,)).fetchone()
    assert status == "needs_review"
    assert total == 16460
    problems = db.execute(
        "SELECT kind, message FROM exceptions WHERE order_id = %s AND status = 'open'",
        (oid,)).fetchall()
    assert problems == [("shortage", "Line 3: short by 3 box (requested 10, available 7)")]
    assert active_reservations(db, oid) == []
    assert stock(db) == START_STOCK


# ---------- approve ----------

def test_staff_cannot_approve(db):
    oid = blueprint_id(db)
    with pytest.raises(psycopg.Error, match="not allowed"):
        with db.transaction():
            approve(db, oid, "ana.staff")
    assert active_reservations(db, oid) == []


def test_approve_reserves_what_exists(db):
    oid = blueprint_id(db)
    assert approve(db, oid, "ben.approver") == ("partially_reserved", 1, 1)
    assert active_reservations(db, oid) == [(1, 12), (2, 120), (3, 70)]
    assert stock(db) == AFTER_APPROVE
    still_open = db.execute(
        "SELECT count(*) FROM exceptions WHERE order_id = %s AND status = 'open'",
        (oid,)).fetchone()[0]
    assert still_open == 0


def test_approving_twice_changes_nothing(db):
    oid = blueprint_id(db)
    approve(db, oid, "ben.approver")
    approve(db, oid, "ben.approver")
    approvals = db.execute(
        "SELECT count(*) FROM approvals WHERE order_id = %s", (oid,)).fetchone()[0]
    assert approvals == 1
    assert len(active_reservations(db, oid)) == 3
    assert stock(db) == AFTER_APPROVE


def test_big_order_needs_two_approvers(db):
    oid = blueprint_id(db)
    db.execute("UPDATE settings SET value = '10000' WHERE key = 'second_approver_threshold_php'")
    first = approve(db, oid, "ben.approver")
    assert first[1:] == (1, 2)            # 1 approval so far, 2 needed
    assert active_reservations(db, oid) == []
    assert stock(db) == START_STOCK
    second = approve(db, oid, "carla.approver")
    assert second == ("partially_reserved", 2, 2)
    assert stock(db) == AFTER_APPROVE


# ---------- reject, cancel, expire ----------

def test_reject_needs_reason_and_blocks_approval(db):
    oid = blueprint_id(db)
    with pytest.raises(psycopg.Error):
        with db.transaction():
            db.execute("SELECT * FROM reject_order(%s, 'carla.approver', '')", (oid,))
    status = db.execute(
        "SELECT result_status FROM reject_order(%s, 'carla.approver', 'Wrong PO')",
        (oid,)).fetchone()[0]
    assert status == "rejected"
    with pytest.raises(psycopg.Error, match="cannot be approved"):
        with db.transaction():
            approve(db, oid, "ben.approver")


def test_cancel_gives_stock_back(db):
    oid = blueprint_id(db)
    approve(db, oid, "ben.approver")
    result = db.execute(
        "SELECT result_status, reservations_released FROM cancel_order(%s, 'carla.approver', 'Customer called')",
        (oid,)).fetchone()
    assert result == ("cancelled", 3)
    assert stock(db) == START_STOCK


def test_expired_reservations_give_stock_back(db):
    oid = blueprint_id(db)
    approve(db, oid, "ben.approver")
    db.execute(
        """UPDATE reservations SET expires_at = now() - interval '1 minute'
           WHERE status = 'active'
             AND order_line_id IN (SELECT id FROM order_lines WHERE order_id = %s)""", (oid,))
    expired = db.execute("SELECT * FROM expire_reservations()").fetchall()
    assert expired == [(oid, 3)]
    assert stock(db) == START_STOCK


def test_decisions_are_audited(db):
    oid = blueprint_id(db)
    approve(db, oid, "ben.approver")
    rows = db.execute(
        """SELECT a.action, u.username FROM audit_log a
           LEFT JOIN app_users u ON u.id = a.actor_user_id
           WHERE a.entity_id = %s AND a.action IN ('order.drafted', 'order.approved')
           ORDER BY a.id""", (oid,)).fetchall()
    assert rows == [("order.drafted", None), ("order.approved", "ben.approver")]


# ---------- n8n security (from Step 8) ----------

def test_n8n_can_approve_through_function(app_db):
    oid = blueprint_id(app_db)
    assert approve(app_db, oid, "ben.approver")[0] == "partially_reserved"
    assert stock(app_db) == AFTER_APPROVE


@pytest.mark.parametrize("forbidden_sql", [
    "UPDATE orders SET status = 'approved'",
    "DELETE FROM stock_movements",
    "SELECT release_reservations(1)",
])
def test_n8n_cannot_skip_the_functions(app_db, forbidden_sql):
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        app_db.execute(forbidden_sql)
