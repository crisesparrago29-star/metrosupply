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