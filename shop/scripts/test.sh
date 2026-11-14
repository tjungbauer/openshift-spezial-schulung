#!/usr/bin/env bash
# Unit tests for all Python services, in a local virtualenv (.venv, Python 3.12).
#   scripts/test.sh                 all services
#   scripts/test.sh catalog         one service
#   PYTHON=python3.12 scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON="${PYTHON:-python3.12}"
SERVICES=("$@")
[[ ${#SERVICES[@]} -gt 0 ]] || SERVICES=(catalog cart orders review)

scripts/sync-common.sh --check

if [[ ! -x .venv/bin/python ]]; then
  echo "creating .venv with ${PYTHON}"
  "${PYTHON}" -m venv .venv
fi
# orders/requirements.txt is a superset of the other two
.venv/bin/pip install --quiet --disable-pip-version-check -r orders/requirements.txt -r requirements-dev.txt

status=0
for service in "${SERVICES[@]}"; do
  echo "── ${service} ──────────────────────────────────────────"
  # shellcheck disable=SC2016  # the backticks are part of Starlette's warning text
  (cd "${service}" && PYTHONPATH=. ../.venv/bin/python -m pytest -q -W 'ignore:Using `httpx`' tests) || status=1
done
exit "${status}"
