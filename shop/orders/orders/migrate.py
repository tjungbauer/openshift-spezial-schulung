"""python -m orders.migrate – create the orders table, then exit.

Used by the migration Job of the PostgreSQL variant. orders also runs the
same migration itself before it reports ready, so the Job is optional.
Waits up to MIGRATE_TIMEOUT_S (default 60) for the database to come up.
"""

import os
import sys
import time

from . import db
from .shopkit import log, setup_logging


def main() -> int:
    setup_logging("orders-migrate")
    deadline = time.monotonic() + float(os.getenv("MIGRATE_TIMEOUT_S", "60"))
    while True:
        try:
            db.migrate()
            log.info("migration done", extra={"fields": {"database": db.kind()}})
            return 0
        except Exception as error:  # database not reachable yet
            if time.monotonic() > deadline:
                log.error("migration failed", extra={"fields": {"error": str(error)}})
                return 1
            log.info("database not ready, retrying", extra={"fields": {"error": str(error)}})
            time.sleep(3)


if __name__ == "__main__":
    sys.exit(main())
