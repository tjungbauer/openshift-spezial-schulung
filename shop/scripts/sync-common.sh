#!/usr/bin/env bash
# Copy common/shopkit.py into every Python service (each image stays self-contained).
#   scripts/sync-common.sh          copy
#   scripts/sync-common.sh --check  only check that all copies are identical
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=common/shopkit.py
status=0
for service in catalog cart orders review; do
  target="${service}/${service}/shopkit.py"
  if [[ "${1:-}" == "--check" ]]; then
    if ! cmp -s "${SOURCE}" "${target}"; then
      echo "OUT OF DATE: ${target} differs from ${SOURCE} – run: make sync-common" >&2
      status=1
    fi
  else
    cp "${SOURCE}" "${target}"
    echo "copied ${SOURCE} -> ${target}"
  fi
done
exit "${status}"
