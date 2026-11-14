"""Storage for orders: SQLite by default, PostgreSQL when DATABASE_URL is set.

SQLite writes to $DATA_DIR/orders.db (default /var/lib/shop) – an emptyDir
in the default deployment, so orders are lost when the pod restarts.

The SQL is plain enough for both databases; only the placeholder differs.
"""

import json
import os
import sqlite3
from contextlib import closing
from pathlib import Path

DATABASE_URL = os.getenv("DATABASE_URL", "")
DATA_DIR = Path(os.getenv("DATA_DIR", "/var/lib/shop"))

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS orders (
           id          TEXT PRIMARY KEY,
           session_id  TEXT NOT NULL,
           created     TEXT NOT NULL,
           total_pence INTEGER NOT NULL,
           items       TEXT NOT NULL,
           pod         TEXT NOT NULL
       )""",
    "CREATE INDEX IF NOT EXISTS orders_session ON orders (session_id)",
]


def kind() -> str:
    return "postgresql" if DATABASE_URL else "sqlite"


def persistent() -> bool:
    """Do orders survive a pod restart? PostgreSQL yes; SQLite only on a PVC."""
    return bool(DATABASE_URL) or os.getenv("ORDERS_PERSISTENT", "false").lower() == "true"


def connect():
    if DATABASE_URL:
        import psycopg  # only needed for the PostgreSQL variant

        return psycopg.connect(DATABASE_URL, connect_timeout=3)
    return sqlite3.connect(DATA_DIR / "orders.db", timeout=5)


def _sql(statement: str) -> str:
    return statement.replace("?", "%s") if DATABASE_URL else statement


def migrate() -> None:
    """Create the table if it does not exist yet – safe to run again."""
    with closing(connect()) as conn:
        for statement in SCHEMA:
            conn.execute(statement)
        conn.commit()


def ping() -> bool:
    try:
        with closing(connect()) as conn:
            conn.execute("SELECT 1")
        return True
    except Exception:
        return False


def save(order: dict) -> None:
    with closing(connect()) as conn:
        conn.execute(
            _sql("INSERT INTO orders (id, session_id, created, total_pence, items, pod) VALUES (?, ?, ?, ?, ?, ?)"),
            (
                order["id"],
                order["session_id"],
                order["created"],
                order["total_pence"],
                json.dumps(order["items"]),
                order["pod"],
            ),
        )
        conn.commit()


def list_for_session(session_id: str, limit: int = 20) -> list[dict]:
    with closing(connect()) as conn:
        rows = conn.execute(
            _sql(
                "SELECT id, created, total_pence, items, pod FROM orders"
                " WHERE session_id = ? ORDER BY created DESC LIMIT ?"
            ),
            (session_id, limit),
        ).fetchall()
    return [
        {"id": r[0], "created": r[1], "total_pence": r[2], "items": json.loads(r[3]), "pod": r[4]}
        for r in rows
    ]
