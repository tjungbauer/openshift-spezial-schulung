#!/usr/bin/env bash
# Start every image like OpenShift's restricted-v2 SCC would – an arbitrary UID
# with GID 0 – and check that it answers /health/ready.
#   scripts/check-images.sh
# Rootless podman on macOS cannot map UID 1000680000; use the rootful
# connection of the podman machine:
#   PODMAN="podman --connection podman-machine-default-root" scripts/check-images.sh
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

TEST_UID="${TEST_UID:-1000680000}"
status=0
port=18180

for service in "${SERVICES[@]}"; do
  port=$((port + 1))
  name="shop-check-${service}"
  extra=()
  # web resolves its backends at start; an unroutable address keeps it independent
  [[ "${service}" == "web" ]] && extra=(--add-host catalog:192.0.2.1 --add-host cart:192.0.2.1 --add-host orders:192.0.2.1 --add-host review:192.0.2.1)
  podman_cmd rm -f "${name}" >/dev/null 2>&1 || true
  podman_cmd run -d --name "${name}" --platform "${PLATFORM}" --user "${TEST_UID}:0" \
    -p "${port}:8080" ${extra[@]+"${extra[@]}"} "$(local_image "${service}")" >/dev/null

  result="no answer"
  for _ in $(seq 1 40); do
    if curl -fs "http://localhost:${port}/health/ready" >/dev/null 2>&1; then result="ready"; break; fi
    sleep 1
  done
  user="$(podman_cmd top "${name}" huser 2>/dev/null | tail -1 | tr -d ' ' || true)"
  if [[ "${result}" == "ready" ]]; then
    echo "ok    ${service}: /health/ready answered, running as UID ${user:-?}"
  else
    echo "FAIL  ${service}: ${result} – logs:"; podman_cmd logs "${name}" 2>&1 | tail -5 | sed 's/^/      /'
    status=1
  fi
  podman_cmd rm -f "${name}" >/dev/null 2>&1 || true
done
exit "${status}"
