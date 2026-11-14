#!/usr/bin/env bash
# Validate the manifests offline: kustomize build + kubeconform for the base,
# the dev overlay and every component (each on top of the base, then all together).
# Also fails if anything cluster-scoped would be created (namespace-admin rights only).
#   scripts/validate.sh
# Needs kustomize and kubeconform, and internet access for the schemas:
# ServiceMonitor from the datreeio CRDs catalog, Route from melmorabity/openshift-json-schemas
# (override with KUBECONFORM_SCHEMAS / OPENSHIFT_SCHEMAS for a mirror).
set -euo pipefail
cd "$(dirname "$0")/.."

KUBE_VERSION="${KUBE_VERSION:-1.33.0}"
DEFAULT_CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
CRD_SCHEMAS="${KUBECONFORM_SCHEMAS:-${DEFAULT_CRD_SCHEMAS}}"
# OpenShift types (Route) are not in the CRDs catalog – strict schemas for OpenShift 4.18:
DEFAULT_OPENSHIFT_SCHEMAS='https://raw.githubusercontent.com/melmorabity/openshift-json-schemas/main/v4.18-standalone-strict/{{.ResourceKind}}.json'
OPENSHIFT_SCHEMAS="${OPENSHIFT_SCHEMAS:-${DEFAULT_OPENSHIFT_SCHEMAS}}"
NAMESPACED_KINDS="ConfigMap Deployment Service Route Secret StatefulSet Job CronJob NetworkPolicy ServiceMonitor PersistentVolumeClaim"
COMPONENTS=(networkpolicies monitoring persistent-orders postgres backup)

# temporary overlays must sit inside the tree: kustomize only accepts relative paths
TMP="deploy/.validate-tmp"
rm -rf "${TMP}"; mkdir -p "${TMP}"
trap 'rm -rf "${TMP}"' EXIT
status=0

validate() {  # validate NAME KUSTOMIZATION-DIR
  local name="$1" dir="$2" out="${TMP}/$1.yaml" kinds unexpected
  if ! kustomize build "${dir}" > "${out}"; then
    echo "FAIL  ${name}: kustomize build"; status=1; return
  fi
  if ! kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION}" \
       -schema-location default -schema-location "${CRD_SCHEMAS}" -schema-location "${OPENSHIFT_SCHEMAS}" "${out}" > "${TMP}/kc.txt" 2>&1; then
    echo "FAIL  ${name}: kubeconform"; sed 's/^/      /' "${TMP}/kc.txt"; status=1; return
  fi
  kinds="$(grep '^kind:' "${out}" | awk '{print $2}' | sort -u | xargs)"
  unexpected=""
  for kind in ${kinds}; do
    [[ " ${NAMESPACED_KINDS} " == *" ${kind} "* ]] || unexpected="${unexpected} ${kind}"
  done
  if [[ -n "${unexpected}" ]]; then
    echo "FAIL  ${name}: not on the namespaced allow-list:${unexpected}"; status=1; return
  fi
  if grep -q '^  namespace:' "${out}"; then
    echo "FAIL  ${name}: a fixed namespace is set – the shop must deploy into any namespace"; status=1; return
  fi
  echo "ok    ${name}: $(tail -1 "${TMP}/kc.txt" | sed 's/^Summary: //')  [${kinds}]"
}

overlay_with() {  # the dev overlay with the given components switched on – as a student would do it
  local dir="${TMP}/overlay-$1"
  shift
  mkdir -p "${dir}"   # same depth as deploy/overlays/dev, so ../../base still works
  cp deploy/overlays/dev/kustomization.yaml "${dir}/"
  printf 'components:\n' >> "${dir}/kustomization.yaml"
  for c in "$@"; do printf -- '- ../../components/%s\n' "${c}" >> "${dir}/kustomization.yaml"; done
  echo "${dir}"
}

validate base deploy/base
validate overlay-dev deploy/overlays/dev
validate overlay-prod deploy/overlays/prod
for c in "${COMPONENTS[@]}"; do
  case "${c}" in
    backup) validate "component-${c}" "$(overlay_with "${c}" postgres "${c}")" ;;   # backup needs postgres
    *)      validate "component-${c}" "$(overlay_with "${c}" "${c}")" ;;
  esac
done
validate all-components "$(overlay_with all "${COMPONENTS[@]}")"
exit "${status}"
