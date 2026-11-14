#!/usr/bin/env bash
# Tag the local images and push them to $REGISTRY/$IMAGE_PREFIX<service>$IMAGE_SUFFIX:$IMAGE_TAG.
#   REGISTRY=nexus.acme.example:5000 IMAGE_PREFIX=workshop/shop-group1- scripts/push.sh
#   REGISTRY=quay.io/tjungbau IMAGE_SUFFIX=-dev IMAGE_TAG=shop-test-dev scripts/push.sh
# Checks that every repository is reachable before pushing, and afterwards that
# the registry serves the tag with exactly the image we built (same image ID).
# Log in first: podman login <registry>
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=("${SERVICES[@]}")

# 1. all repositories reachable? (fail before pushing anything)
missing=0
for service in "${targets[@]}"; do
  if podman_cmd search --list-tags --limit 1 "$(remote_repo "${service}")" >/dev/null 2>&1; then
    echo "ok    repository $(remote_repo "${service}") is reachable"
  else
    echo "FAIL  repository $(remote_repo "${service}") not found or no access (create it / podman login)" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || exit 1

# 2. push, 3. verify: pull the tag back – the image ID must be the one we built
for service in "${targets[@]}"; do
  local_id="$(image_id "$(local_image "${service}")")"
  [[ -n "${local_id}" ]] || { echo "missing image $(local_image "${service}") – run: make build" >&2; exit 1; }
  echo "── pushing $(remote_image "${service}")"
  podman_cmd tag "$(local_image "${service}")" "$(remote_image "${service}")"
  podman_cmd push --quiet "$(remote_image "${service}")"
  remote_id=""
  for _ in $(seq 1 6); do   # give the registry a moment if needed
    remote_id="$(remote_image_id "$(remote_image "${service}")" || true)"
    [[ "${remote_id}" == "${local_id}" ]] && break
    sleep 5
  done
  if [[ "${remote_id}" == "${local_id}" ]]; then
    echo "ok    $(remote_image "${service}") is in the registry (image ${local_id:0:12})"
  else
    echo "FAIL  $(remote_image "${service}"): built ${local_id:0:12}, registry has ${remote_id:0:12}" >&2
    exit 1
  fi
done
