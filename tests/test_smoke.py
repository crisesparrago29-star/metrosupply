import os

import psycopg
from dotenv import load_dotenv

load_dotenv()  # reads POSTGRES_USER and POSTGRES_PASSWORD from .env


def test_n8n_wrote_a_row():
    with psycopg.connect(
        host="localhost",
        port=5432,
        dbname="metrosupply",
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    ) as conn:
        count = conn.execute("SELECT count(*) FROM hello_test").fetchone()[0]
    assert count >= 1, "Expected at least one row written by n8n"
