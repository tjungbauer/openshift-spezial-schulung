"""python -m review – start the service."""

from .main import app
from .shopkit import run

run(app)
