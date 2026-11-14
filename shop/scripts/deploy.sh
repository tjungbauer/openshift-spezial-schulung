#!/usr/bin/env bash
# Deploy the shop with one of the overlays (namespace-admin rights are enough).
#   scripts/deploy.sh                                   overlay dev, current project
#   OVERLAY=prod NAMESPACE=shop scripts/deploy.sh       overlay prod into project "shop"
#   REGISTRY=... IMAGE_SUFFIX=... IMAGE_TAG=... scripts/deploy.sh
# With SET_IMAGES=true the overlay is first pointed at
# $REGISTRY/$IMAGE_PREFIX<service>$IMAGE_SUFFIX:$IMAGE_TAG (needs kustomize).
# NAMESPACE is created with oc new-project if it does not exist.
# RESTART=true restarts all shop Deployments after the apply (needed after
# pushing a new image under the same tag; imagePullPolicy is Always).
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

OVERLAY="${OVERLAY:-dev}"
OVERLAY_DIR="${SHOP_DIR}/deploy/overlays/${OVERLAY}"
SET_IMAGES="${SET_IMAGES:-false}"
[[ -f "${OVERLAY_DIR}/kustomization.yaml" ]] || { echo "no overlay ${OVERLAY_DIR}" >&2; exit 1; }

oc whoami >/dev/null 2>&1 || { echo "not logged in – run: oc login ..." >&2; exit 1; }

NAMESPACE="${NAMESPACE:-$(oc project -q)}"
if ! oc get project "${NAMESPACE}" >/dev/null 2>&1; then
  oc new-project "${NAMESPACE}" --skip-config-write >/dev/null
  echo "created project ${NAMESPACE}"
fi
echo "deploying overlay ${OVERLAY} into project ${NAMESPACE}"

if [[ "${SET_IMAGES}" == "true" ]]; then
  command -v kustomize >/dev/null 2>&1 || { echo "SET_IMAGES=true needs kustomize" >&2; exit 1; }
  for service in "${SERVICES[@]}"; do
    (cd "${OVERLAY_DIR}" && kustomize edit set image "shop-${service}=$(remote_image "${service}")")
  done
  echo "overlay ${OVERLAY} now uses $(remote_image '<service>')"
fi

oc apply -n "${NAMESPACE}" -k "${OVERLAY_DIR}"
if [[ "${RESTART:-false}" == "true" ]]; then
  # a re-pushed tag (same name, new image) does not change the Deployment – restart to pull it
  oc rollout restart -n "${NAMESPACE}" deployment -l app.kubernetes.io/part-of=shop
fi
for service in "${SERVICES[@]}"; do
  oc rollout status -n "${NAMESPACE}" "deployment/${service}" --timeout=300s
done
echo "shop (${OVERLAY}): https://$(oc get route web -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
