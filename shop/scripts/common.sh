# shellcheck shell=bash disable=SC2034  # the variables are used by the scripts that source this file
# Settings shared by the shop scripts – every value can be overridden from
# the environment (the Makefile passes its variables through).

SHOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES=(catalog cart orders review web)

PODMAN="${PODMAN:-podman}"
PLATFORM="${PLATFORM:-linux/amd64}"
VERSION="${VERSION:-$(cat "${SHOP_DIR}/VERSION")}"
REVISION="${REVISION:-$(git -C "${SHOP_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
CREATED="${CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SOURCE="${SOURCE:-https://example.com/acme/shop}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.org/simple}"

# where make push sends the images:  $REGISTRY/$IMAGE_PREFIX<service>$IMAGE_SUFFIX:$IMAGE_TAG
#   e.g. REGISTRY=nexus.acme.example:5000 IMAGE_PREFIX=workshop/shop-group1-
#        -> nexus.acme.example:5000/workshop/shop-group1-catalog:1.0.0
#   e.g. REGISTRY=quay.io/tjungbau IMAGE_SUFFIX=-dev IMAGE_TAG=shop-test-dev
#        -> quay.io/tjungbau/shop-catalog-dev:shop-test-dev
REGISTRY="${REGISTRY:-quay.io/acme-workshop}"
IMAGE_PREFIX="${IMAGE_PREFIX:-shop-}"
IMAGE_SUFFIX="${IMAGE_SUFFIX:-}"
IMAGE_TAG="${IMAGE_TAG:-${VERSION}}"

local_image()  { echo "localhost/shop-$1:${VERSION}"; }
remote_repo()  { echo "${REGISTRY}/${IMAGE_PREFIX}$1${IMAGE_SUFFIX}"; }
remote_image() { echo "$(remote_repo "$1"):${IMAGE_TAG}"; }

# image_id IMAGE – the image ID (digest of the image config; unchanged by push and pull)
image_id() {
  podman_cmd image inspect "$1" --format '{{.Id}}' 2>/dev/null
}

# remote_image_id IMAGE – pull IMAGE by its tag from the registry and print its ID
# (a manifest request by tag – unlike tag lists, not served from a stale cache)
remote_image_id() {
  podman_cmd pull --quiet --platform "${PLATFORM}" "$1" 2>/dev/null
}

# PODMAN may contain options ("podman --connection x") – split it on purpose
podman_cmd() {
  # shellcheck disable=SC2086
  ${PODMAN} "$@"
}
