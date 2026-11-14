"""python -m cart – start the service."""

from .main import app
from .shopkit import run

run(app)
