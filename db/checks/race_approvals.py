"""Phase 3 race test: many approvals at the same moment must never over-reserve stock.

What it does:
  1. Builds a throwaway database, metrosupply_race (migrations + seed data).
  2. Each round: creates 8 orders that each want 3 boxes of garbage bags
     (24 boxes wanted, only 7 boxes = 70 packs in stock).
  3. Fires all 8 approvals at the same instant, from 8 separate n8n logins.
  4. Checks: never more than 70 packs reserved, available never below zero.
  5. Cancels the round's orders so stock goes back to 70, then repeats.
  6. Deletes the throwaway database at the end.

Run from the project folder:  python db/checks/race_approvals.py
Your real database (metrosupply) is never touched.
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import psycopg
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]      # the project folder
RACE_DB = "metrosupply_race"
ROUNDS = 50
RACERS = 8                                       # approvals fired at the same moment
BOXES_EACH = 3
STOCK_PACKS = 70                                 # 7 boxes x 10 packs, from the seed

load_dotenv(ROOT / ".env")
ADMIN_USER = os.environ["POSTGRES_USER"]
ADMIN_PASS = os.environ["POSTGRES_PASSWORD"]
APP_PASS = os.environ["APP_N8N_PASSWORD"]


def connect(dbname, user=ADMIN_USER, password=ADMIN_PASS):
    return psycopg.connect(host="localhost", port=5432, dbname=dbname,
                           user=user, password=password, autocommit=True)


def build_race_db():
    print(f"1. Building throwaway database {RACE_DB} ...")
    with connect("postgres") as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {RACE_DB} WITH (FORCE)")
        conn.execute(f"CREATE DATABASE {RACE_DB}")
    subprocess.run(["./db/migrate.sh"], cwd=ROOT, check=True,
                   env={**os.environ, "MIGRATE_DB": RACE_DB}, stdout=subprocess.DEVNULL)
    with open(ROOT / "db/seed/dev_seed.sql", "rb") as seed:
        subprocess.run(["docker", "compose", "exec", "-T", "postgres", "psql",
                        "-U", ADMIN_USER, "-d", RACE_DB, "-v", "ON_ERROR_STOP=1", "-q"],
                       cwd=ROOT, check=True, stdin=seed, stdout=subprocess.DEVNULL)
    print("   ready: migrations applied, seed loaded")


def drop_race_db():
    with connect("postgres") as conn:
        conn.execute(f"DROP DATABASE IF EXISTS {RACE_DB} WITH (FORCE)")
    print(f"6. Throwaway database {RACE_DB} deleted. Your real database was never touched.")


def garbage_bag_stock(conn):
    return conn.execute(
        "SELECT on_hand, reserved, available FROM available_stock WHERE sku = 'GB-XL'"
    ).fetchone()


def make_orders(admin, round_no):
    lines = f'[{{"product":"garbage bags", "qty":{BOXES_EACH}, "unit":"boxes"}}]'
    ids = []
    for i in range(1, RACERS + 1):
        event_id = admin.execute(
            "SELECT event_id FROM record_intake_event('manual', %s, 'race test order')",
            (f"race-{round_no}-{i}",)).fetchone()[0]
        order_id = admin.execute(
            "SELECT draft_order_id FROM create_draft_order(%s, 'BAYVIEW', %s, %s)",
            (event_id, f"RACE-{round_no}-{i}", lines)).fetchone()[0]
        ids.append(order_id)
    return ids


def fire_at_once(order_ids):
    """Each racer has its own n8n login. All wait at the barrier, then go together."""
    conns = [connect(RACE_DB, "app_n8n", APP_PASS) for _ in order_ids]
    barrier = threading.Barrier(len(order_ids))
    errors = []

    def racer(conn, order_id):
        barrier.wait()                      # everyone starts at the same instant
        try:
            conn.execute("SELECT * FROM approve_order(%s, 'ben.approver')", (order_id,))
        except Exception as exc:            # record it, the checks below will fail
            errors.append(f"order {order_id}: {exc}")

    threads = [threading.Thread(target=racer, args=(c, o)) for c, o in zip(conns, order_ids)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for c in conns:
        c.close()
    return errors


def reserved_per_order(admin, order_ids):
    rows = admin.execute(
        """SELECT o.id, coalesce(sum(r.qty) FILTER (WHERE r.status = 'active'), 0)
           FROM orders o
           JOIN order_lines l ON l.order_id = o.id
           LEFT JOIN reservations r ON r.order_line_id = l.id
           WHERE o.id = ANY(%s)
           GROUP BY o.id""", (order_ids,)).fetchall()
    return sorted((int(q) for _, q in rows), reverse=True)


def cancel_all(admin, order_ids):
    for order_id in order_ids:
        admin.execute("SELECT * FROM cancel_order(%s, 'carla.approver', 'race test cleanup')",
                      (order_id,))


def main():
    build_race_db()
    failures = 0
    started = time.time()
    print(f"2-5. Running {ROUNDS} rounds: {RACERS} approvals at once, "
          f"each wants {BOXES_EACH} boxes, only {STOCK_PACKS // 10} boxes exist")
    try:
        with connect(RACE_DB) as admin:
            for round_no in range(1, ROUNDS + 1):
                order_ids = make_orders(admin, round_no)
                errors = fire_at_once(order_ids)
                on_hand, reserved, available = garbage_bag_stock(admin)
                split = reserved_per_order(admin, order_ids)

                ok = (not errors and reserved <= on_hand and available >= 0
                      and reserved == STOCK_PACKS and sum(split) == STOCK_PACKS)
                if not ok:
                    failures += 1
                print(f"   round {round_no:2}: reserved {int(reserved):3} of {int(on_hand)} packs, "
                      f"available {int(available):3}, per order {split} "
                      f"{'OK' if ok else 'FAIL'}")
                for e in errors:
                    print(f"      error: {e}")

                cancel_all(admin, order_ids)
                if garbage_bag_stock(admin)[2] != STOCK_PACKS:
                    failures += 1
                    print("      FAIL: stock did not return to 70 after cancelling")
    finally:
        drop_race_db()

    seconds = time.time() - started
    if failures == 0:
        print(f"RACE TEST PASSED: {ROUNDS}/{ROUNDS} rounds, never more than "
              f"{STOCK_PACKS // 10} boxes reserved ({seconds:.1f}s)")
        return 0
    print(f"RACE TEST FAILED: {failures} problem(s) in {ROUNDS} rounds")
    return 1


if __name__ == "__main__":
    sys.exit(main())
