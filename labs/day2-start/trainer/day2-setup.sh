#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Day 2 – trainer setup: a second namespace <NS>-shop per student
#  Run:     ./day2-setup.sh NAMESPACE[:USER] ...         create / update
#           ./day2-setup.sh --delete NAMESPACE ...       delete <NS>-shop
#  Expects: oc logged in as cluster-admin; lab-05-setup.sh already ran
#           (the Argo CD instance "argocd" in NAMESPACE)
#
#  Per student: namespace <NS>-shop, labelled
#  argocd.argoproj.io/managed-by=<NS> (the student's Argo CD may deploy
#  there), and a RoleBinding "admin" for USER (default: the namespace name).
#  Why a second namespace: the shop closes its namespace with NetworkPolicies –
#  in <NS> they would also cut off the student's Argo CD.
# ---------------------------------------------------------------------------
set -euo pipefail

DELETE=0
usage() { sed -n '3,15p' "$0" | sed 's/^#  \{0,1\}//'; }

[[ $# -gt 0 ]] || { usage >&2; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  --delete)  DELETE=1; shift ;;
esac
[[ $# -gt 0 ]] || { usage >&2; exit 1; }

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in – run 'oc login' first" >&2; exit 1; }

for item in "$@"; do
  ns="${item%%:*}"
  user="${item#*:}"
  [[ "${item}" == *:* ]] || user="${ns}"
  shop="${ns}-shop"

  if [[ ${DELETE} -eq 1 ]]; then
    oc delete namespace "${shop}" --ignore-not-found --wait=false
    continue
  fi

  oc -n "${ns}" get argocd argocd >/dev/null 2>&1 \
    || echo "WARNING: no Argo CD instance in ${ns} – run lab-05-setup.sh ${item} first" >&2
  oc get namespace "${shop}" >/dev/null 2>&1 || oc create namespace "${shop}" >/dev/null
  oc label namespace "${shop}" "argocd.argoproj.io/managed-by=${ns}" --overwrite >/dev/null
  oc -n "${shop}" create rolebinding admin --clusterrole=admin --user="${user}" \
    --dry-run=client -o yaml | oc -n "${shop}" apply -f - >/dev/null
  echo "${shop}: managed by the Argo CD in ${ns}, admin for ${user}"
done
