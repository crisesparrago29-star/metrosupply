"""Phase 2: every database rule we proved by hand, as automatic tests."""
from decimal import Decimal

import pytest
from psycopg import errors


def new_product(db, sku):
    """Add a throwaway product for one test (rolled back afterwards)."""
    return db.execute(
        "INSERT INTO products (sku, name, base_unit) VALUES (%s, 'Test item', 'jug') RETURNING id",
        (sku,),
    ).fetchone()[0]


def customer_id(db, code):
    return db.execute("SELECT id FROM customers WHERE code = %s", (code,)).fetchone()[0]


# --- Seed / blueprint -------------------------------------------------------

def test_blueprint_available_stock_is_14_12_7(db):
    rows = db.execute("""
        SELECT a.sku, round(a.available / c.base_qty, 2)
        FROM available_stock a
        JOIN unit_conversions c ON c.product_id = a.product_id
        WHERE (a.sku, c.unit) IN (('HS-5L','jug'), ('JT-12','ctn'), ('GB-XL','box'))
    """).fetchall()
    assert dict(rows) == {"HS-5L": 14, "JT-12": 12, "GB-XL": 7}


# --- What we sell -------------------------------------------------------------

def test_zero_unit_conversion_is_rejected(db):
    pid = new_product(db, "TEST-CONV")
    with pytest.raises(errors.CheckViolation):
        db.execute("INSERT INTO unit_conversions (product_id, unit, base_qty) VALUES (%s, 'ctn', 0)", (pid,))


# --- Prices ---------------------------------------------------------------------

def test_negative_price_is_rejected(db):
    pid = new_product(db, "TEST-NEG")
    with pytest.raises(errors.CheckViolation):
        db.execute("INSERT INTO product_prices (product_id, unit_price, valid_from) VALUES (%s, -50, '2026-11-01')", (pid,))


def test_overlapping_price_periods_are_rejected(db):
    pid = new_product(db, "TEST-OVL")
    db.execute("INSERT INTO product_prices (product_id, unit_price, valid_from, valid_to) VALUES (%s, 450, '2026-11-01', '2026-12-01')", (pid,))
    with pytest.raises(errors.ExclusionViolation):
        db.execute("INSERT INTO product_prices (product_id, unit_price, valid_from) VALUES (%s, 480, '2026-11-15')", (pid,))


def test_back_to_back_price_periods_are_allowed(db):
    pid = new_product(db, "TEST-ADJ")
    db.execute("INSERT INTO product_prices (product_id, unit_price, valid_from, valid_to) VALUES (%s, 450, '2026-11-01', '2026-12-01')", (pid,))
    db.execute("INSERT INTO product_prices (product_id, unit_price, valid_from) VALUES (%s, 480, '2026-12-01')", (pid,))


# --- Stock ----------------------------------------------------------------------

def test_stock_ledger_cannot_be_edited(db):
    with pytest.raises(errors.RaiseException):
        db.execute("UPDATE stock_movements SET qty = 999 WHERE id = (SELECT min(id) FROM stock_movements)")


# --- Orders and history -------------------------------------------------------

def test_vat_is_calculated_automatically(db):
    vat = db.execute(
        "INSERT INTO orders (customer_id, po_number, total_amount) VALUES (%s, 'TEST-VAT', 1120) RETURNING vat_amount",
        (customer_id(db, "CLEANPRO"),),
    ).fetchone()[0]
    assert vat == Decimal("120.00")


def test_duplicate_po_from_same_customer_is_rejected(db):
    cid = customer_id(db, "CLEANPRO")
    db.execute("INSERT INTO orders (customer_id, po_number) VALUES (%s, 'TEST-PO-1')", (cid,))
    with pytest.raises(errors.UniqueViolation):
        db.execute("INSERT INTO orders (customer_id, po_number) VALUES (%s, 'TEST-PO-1')", (cid,))


def test_same_message_cannot_be_saved_twice(db):
    sql = "INSERT INTO intake_events (source, source_ref, raw_text) VALUES ('telegram', 'TEST-MSG-1', 'hello')"
    db.execute(sql)
    with pytest.raises(errors.UniqueViolation):
        db.execute(sql)


def test_audit_log_cannot_be_deleted(db):
    db.execute("INSERT INTO audit_log (action, entity) VALUES ('test.hello', 'orders')")
    with pytest.raises(errors.RaiseException):
        db.execute("DELETE FROM audit_log")


# --- The limited n8n login ----------------------------------------------------

def test_app_n8n_can_read_stock(app_db):
    count = app_db.execute("SELECT count(*) FROM available_stock").fetchone()[0]
    assert count >= 4


def test_app_n8n_cannot_delete_the_ledger(app_db):
    with pytest.raises(errors.InsufficientPrivilege):
        app_db.execute("DELETE FROM stock_movements")


def test_app_n8n_cannot_add_products(app_db):
    with pytest.raises(errors.InsufficientPrivilege):
        app_db.execute("INSERT INTO products (sku, name, base_unit) VALUES ('TEST-X', 'X', 'jug')")
