#!/usr/bin/env bash
# Build the shop images (default: all) for linux/amd64 with version and git revision.
#   scripts/build.sh                 all images
#   scripts/build.sh catalog web     only these
#   VERSION=2.0.0 scripts/build.sh catalog
#   PIP_INDEX_URL=https://nexus.acme.example/repository/pypi/simple scripts/build.sh
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=("${SERVICES[@]}")

"${SHOP_DIR}/scripts/sync-common.sh" --check

for service in "${targets[@]}"; do
  echo "── building $(local_image "${service}") (${PLATFORM}, revision ${REVISION})"
  args=(
    --platform "${PLATFORM}"
    --build-arg "APP_VERSION=${VERSION}"
    --build-arg "APP_REVISION=${REVISION}"
    --build-arg "APP_CREATED=${CREATED}"
    --build-arg "APP_SOURCE=${SOURCE}"
    --tag "$(local_image "${service}")"
  )
  [[ "${service}" == "web" ]] || args+=(--build-arg "PIP_INDEX_URL=${PIP_INDEX_URL}")
  podman_cmd build "${args[@]}" "${SHOP_DIR}/${service}"
done
