#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 05 – trainer setup: an Argo CD instance in every student namespace
#  Run:     ./lab-05-setup.sh NAMESPACE[:USER] ...        create / update
#           ./lab-05-setup.sh --delete NAMESPACE ...      remove the instance
#  Expects: oc logged in as cluster-admin, OpenShift GitOps operator installed
#
#  Per namespace: the ArgoCD CR "argocd" (trainer/argocd.yaml), a Role that
#  allows Applications, and a RoleBinding for USER (default: the namespace
#  name, e.g. user-01). Run it before the lab – an instance needs 1-2 minutes.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DELETE=0

usage() {
  sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'
}

[[ $# -gt 0 ]] || { usage >&2; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  --delete)  DELETE=1; shift ;;
esac
[[ $# -gt 0 ]] || { usage >&2; exit 1; }

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in – run 'oc login' first" >&2; exit 1; }
oc get crd argocds.argoproj.io >/dev/null 2>&1 \
  || { echo "ERROR: no ArgoCD CRD – install the OpenShift GitOps operator first" >&2; exit 1; }

for item in "$@"; do
  ns="${item%%:*}"
  user="${item#*:}"
  [[ "${item}" == *:* ]] || user="${ns}"

  if [[ ${DELETE} -eq 1 ]]; then
    oc -n "${ns}" delete argocd argocd --ignore-not-found
    oc -n "${ns}" delete rolebinding,role lab-05-argocd-applications --ignore-not-found
    continue
  fi

  oc get namespace "${ns}" >/dev/null 2>&1 || oc new-project "${ns}" >/dev/null
  oc -n "${ns}" apply -f "${SCRIPT_DIR}/argocd.yaml"
  oc -n "${ns}" apply -f "${SCRIPT_DIR}/rbac.yaml"
  oc -n "${ns}" create rolebinding lab-05-argocd-applications \
    --role=lab-05-argocd-applications --user="${user}" \
    --dry-run=client -o yaml | oc -n "${ns}" apply -f -
  echo "${ns}: Argo CD instance requested, Applications allowed for user ${user}"
done

[[ ${DELETE} -eq 1 ]] && exit 0

echo
echo "Waiting for the Argo CD servers ..."
for item in "$@"; do
  ns="${item%%:*}"
  for _ in $(seq 1 60); do
    oc -n "${ns}" get deployment argocd-server >/dev/null 2>&1 && break
    sleep 5
  done
  if oc -n "${ns}" rollout status deployment/argocd-server --timeout=300s >/dev/null 2>&1; then
    echo "${ns}: https://$(oc -n "${ns}" get route argocd-server -o jsonpath='{.spec.host}')"
  else
    echo "${ns}: Argo CD not ready – oc -n ${ns} get pods" >&2
  fi
done
