#!/usr/bin/env bash
# Run the whole shop locally in one podman pod (needs the images: make build).
#   scripts/run-local.sh          start (or restart) – then open http://localhost:8080
#   scripts/run-local.sh down     stop and remove the pod
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

POD_FILE="${SHOP_DIR}/local/shop-pod.yaml"

if [[ "${1:-up}" == "down" ]]; then
  sed "s/@VERSION@/${VERSION}/g" "${POD_FILE}" | podman_cmd kube down -
  exit 0
fi

for service in "${SERVICES[@]}"; do
  podman_cmd image exists "$(local_image "${service}")" \
    || { echo "missing image $(local_image "${service}") – run: make build" >&2; exit 1; }
done

sed "s/@VERSION@/${VERSION}/g" "${POD_FILE}" | podman_cmd kube play --replace -

echo "waiting for the shop on http://localhost:8080 ..."
for _ in $(seq 1 60); do
  if curl -fs http://localhost:8080/api/orders/health/ready >/dev/null 2>&1; then
    echo "shop is up: http://localhost:8080   (stop with: make stop-local)"
    exit 0
  fi
  sleep 1
done
echo "shop did not become ready – check: ${PODMAN} pod logs shop" >&2
exit 1
