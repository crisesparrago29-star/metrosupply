"""Phase 6 tests: Telegram identity (user_for_telegram).

Every test runs inside a transaction that is rolled back afterwards (see conftest.py),
so the real app_users rows are never changed.
"""
import psycopg
import pytest

TEST_TELEGRAM_ID = 111111111   # a made-up ID, linked to ben.approver only inside these tests


def who(conn, telegram_id):
    return conn.execute(
        "SELECT username, role FROM user_for_telegram(%s)", (telegram_id,)).fetchall()


def test_unknown_telegram_id_returns_nothing(app_db):
    assert who(app_db, 1) == []


def test_linked_user_is_found_with_role(db):
    db.execute("UPDATE app_users SET telegram_user_id = %s WHERE username = 'ben.approver'",
               (TEST_TELEGRAM_ID,))
    assert who(db, TEST_TELEGRAM_ID) == [("ben.approver", "approver")]


def test_inactive_user_is_not_found(db):
    db.execute("""UPDATE app_users SET telegram_user_id = %s, is_active = false
                  WHERE username = 'ben.approver'""", (TEST_TELEGRAM_ID,))
    assert who(db, TEST_TELEGRAM_ID) == []


def test_n8n_may_ask_who_someone_is(app_db):
    who(app_db, TEST_TELEGRAM_ID)          # must not raise a permission error


def test_n8n_cannot_read_the_users_table(app_db):
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        app_db.execute("SELECT * FROM app_users")