"""Shared test setup: database connections that undo everything after each test."""
import os

import psycopg
import pytest
from dotenv import load_dotenv

load_dotenv()  # reads the passwords from .env


def _connect(user, password):
    return psycopg.connect(host="localhost", port=5432, dbname="metrosupply",
                           user=user, password=password)


@pytest.fixture
def db():
    """Admin connection. Every change made in a test is rolled back afterwards."""
    conn = _connect(os.environ["POSTGRES_USER"], os.environ["POSTGRES_PASSWORD"])
    try:
        yield conn
    finally:
        conn.rollback()
        conn.close()


@pytest.fixture
def app_db():
    """The limited n8n login (app_n8n)."""
    conn = _connect("app_n8n", os.environ["APP_N8N_PASSWORD"])
    try:
        yield conn
    finally:
        conn.rollback()
        conn.close()
