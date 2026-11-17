#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 19 – Canary and fault injection
#  Run:     ./demo-19-mesh-traffic.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; the mesh in ambient mode as in demo 18, and the
#           namespace in its scope (cluster-admin, once:
#           ../18_mesh-onboarding/admin/namespace-in-mesh.sh demo-traffic).
#  The demo runs in the project "demo-traffic" (or NAME), created if missing.
#
#  The shop of demo 18 (ambient, waypoint, shopper) with catalog v1 and v2:
#    0  two versions, no rule – round robin
#    1  canary – 90 % v1, 10 % v2
#    2  fault injection – 50 % of the catalog calls get a 503
#    3  fault injection – 50 % of the catalog calls wait 2 s
#    4  rules gone – back to round robin
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-traffic}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-4); default: all steps
  cleanup                delete the demo objects"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-4]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

cd "${SCRIPT_DIR}" || die "Cannot cd to ${SCRIPT_DIR}"

DEPLOYMENTS="web catalog catalog-v2 cart orders review shopper"
WAIT=30

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

rollouts() {
  local d
  for d in ${DEPLOYMENTS}; do
    oc rollout status "deployment/${d}" --timeout=180s >/dev/null 2>&1 || true
  done
  oc wait --for=condition=Programmed gateway/waypoint --timeout=120s >/dev/null 2>&1 || true
}

collect() {   # let the shopper run for WAIT seconds
  info "   collecting ${WAIT} s of shopper traffic ..."
  sleep "${WAIT}"
}

# who answered the catalog calls in the last WAIT seconds – one log line per request
VERSIONS="for d in catalog catalog-v2; do printf '%-11s %s\n' \$d \$(oc logs deployment/\$d --since=${WAIT}s | grep -c '\"path\": \"/products'); done"
# what the shopper got from catalog: calls per status
STATUS="oc logs deployment/shopper --since=${WAIT}s | grep /api/catalog/ | awk '{print \$4}' | sort | uniq -c"
# how long the shopper waited for catalog: average and maximum in seconds
TIMES="oc logs deployment/shopper --since=${WAIT}s | grep /api/catalog/ | awk '{s+=\$5; if (\$5>m) m=\$5} END {printf \"calls %d  avg %.2f s  max %.2f s\\n\", NR, s/NR, m}'"

kiali_url() {
  local host
  host="$(oc -n istio-system get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf "https://%s/console/graph/namespaces/?namespaces=%s&graphType=versionedApp" "${host}" "${DEMO_PROJECT}"
  else
    printf "%s  (console: Service Mesh › Traffic Graph, versioned app graph, namespace %s)" "$(oc whoami --show-console)" "${DEMO_PROJECT}"
  fi
}

base_state() {
  oc apply -k . >/dev/null
  rollouts
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f rules/ --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete -k . --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · Two versions of catalog – no rule"
  if [[ "$(oc get project "${DEMO_PROJECT}" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null)" != enabled ]]; then
    warn "${DEMO_PROJECT} is not in the mesh scope – a cluster-admin runs: ../18_mesh-onboarding/admin/namespace-in-mesh.sh ${DEMO_PROJECT}"
  fi
  show_file catalog-v2.yaml
  run "oc apply -k ."
  rollouts
  run "oc get pods -l app.kubernetes.io/name=catalog -L version"
  collect
  comment "Who answered the catalog calls (requests to /products…):"
  run "${VERSIONS}"
  comment "In Kiali: versioned app graph – catalog v1 and v2"
  run "echo \"$(kiali_url)\""

  discuss \
    "One Service, two Deployments - round robin" \
    "" \
    "The Service catalog selects app.kubernetes.io/name: catalog -> both." \
    "Without a rule each version gets about half of the calls."
}

step1() {
  section "1 · Canary – 90 % v1, 10 % v2"
  [[ "${MODE}" == "1" ]] && base_state
  show_file rules/destinationrule.yaml
  show_file rules/canary-90-10.yaml
  run "oc apply -f rules/destinationrule.yaml -f rules/canary-90-10.yaml"
  collect
  run "${VERSIONS}"
  pause

  discuss \
    "DestinationRule: which versions exist - VirtualService: who gets what" \
    "" \
    "The waypoint applies the weights - the shop does not change." \
    "Next step of the canary: 50/50, then 0/100 - one commit each."
}

step2() {
  section "2 · Fault injection – half of the catalog calls get a 503"
  [[ "${MODE}" == "2" ]] && { base_state; oc apply -f rules/destinationrule.yaml >/dev/null; }
  show_file rules/fault-abort.yaml
  run "oc apply -f rules/fault-abort.yaml"
  collect
  comment "What the shopper got from catalog:"
  run "${STATUS}"
  comment "Reload the shop in the browser – what does the UI do with the errors?"
  pause

  discuss \
    "The waypoint answers 503 - catalog never sees the call" \
    "" \
    "catalog itself is healthy - its own logs show only the calls that got through." \
    "Test your error pages and retries before production does."
}

step3() {
  section "3 · Fault injection – half of the catalog calls wait 2 s"
  [[ "${MODE}" == "3" ]] && { base_state; oc apply -f rules/destinationrule.yaml >/dev/null; }
  show_file rules/fault-delay.yaml
  run "oc apply -f rules/fault-delay.yaml"
  collect
  comment "How long the shopper waited for catalog:"
  run "${TIMES}"
  pause

  discuss \
    "A slow dependency - on purpose" \
    "" \
    "Does web time out? Does the UI show a spinner forever?" \
    "Set timeouts in the caller - or in a VirtualService: timeout: 1s."
}

step4() {
  section "4 · Rules gone – back to round robin"
  [[ "${MODE}" == "4" ]] && base_state
  run "oc delete -f rules/ --ignore-not-found"
  collect
  run "${VERSIONS}"
  run "${STATUS}"

  discuss \
    "Rules are objects - in Git, reviewed, reverted" \
    "" \
    "Delete the VirtualService: the Service's round robin is back." \
    "Alternative for waypoints: Gateway API HTTPRoute (rules/canary-httproute.yaml)."
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════

require_oc_login

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [0-4])
    "step${MODE}"
    ;;
  all)
    cleanup
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-18 --timeout=90s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 19 – Canary and fault injection" "two versions · 90/10 · 503 · delay"
    for i in 0 1 2 3 4; do "step${i}"; done

    takeaways \
      "DestinationRule defines the versions, VirtualService routes between them" \
      "A canary is a change of weights – no redeploy" \
      "Fault injection tests your error handling – the app is not changed" \
      "In ambient mode, L7 rules need the waypoint"
    ;;
esac
