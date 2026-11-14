#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 07 – The shop: many containers, one application
#  Run:     ./demo-07-multi-container.sh [-n|--namespace NAME] [cleanup]
#  Expects: oc logged in; the cluster pulls the shop images from quay.io
#  The demo runs in the project "demo-multi" (or NAME), created if missing.
#
#  1  deploy the shop – five Deployments, five Services, one Route
#  2  the walk-through happens in the browser – the script waits
#  3  back in the terminal: everything is deleted again
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-multi}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[cleanup]"
DEMO_USAGE_EXTRA="  cleanup                only delete the demo objects"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|cleanup) ;;
  *) demo_usage >&2; die "Unknown argument: ${MODE}" ;;
esac

cd "${SCRIPT_DIR}" || die "Cannot cd to ${SCRIPT_DIR}"
DEPLOYMENTS="web catalog cart orders review"

cleanup() {
  info "deleting the shop in ${DEMO_PROJECT} ..."
  oc delete -k . --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

require_oc_login

if [[ "${MODE}" == "cleanup" ]]; then
  cleanup
  success "Cleaned up."
  exit 0
fi

# Ctrl-C or an error: still clean up (question skipped with DEMO_CLEANUP=y|n)
on_exit_cleanup cleanup "Delete the shop? [y/N]"

title "Demo 07 – The shop" "many containers, one application"

section "1 · Deploy the shop"
comment "One kustomization: the shop's base with the dev images"
run "oc kustomize . | grep -E '^kind:' | sort | uniq -c"
run "oc apply -k ."

run "oc get deployment,service,route"
run "oc get pods -o wide"

section "2 · Walk through the shop in the browser"
ROUTE="$(oc get route web -o jsonpath='{.spec.host}')"
comment "Open the shop:"
printf "\n    %shttps://%s%s\n" "${C_BOLD}" "${ROUTE}" "${C_RESET}"

section "3 · Clean up"
# the walk-through is over: delete now, no question on exit any more
on_exit_cleanup ""
run "oc delete -k ."
run "oc get deployment,service,route,pod"

takeaways \
  "One application, five containers, five Deployments" \
  "They find each other by Service name - not by IP" \
  "Each part scales and rolls out on its own" \
  "An optional service can fail - the rest keeps working"
