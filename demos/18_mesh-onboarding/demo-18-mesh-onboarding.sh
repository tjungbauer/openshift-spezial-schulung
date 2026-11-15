#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 18 – The shop joins the mesh
#  Run:     ./demo-18-mesh-onboarding.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; OpenShift Service Mesh 3 in ambient mode (Istio
#           "default" + IstioCNI with profile ambient, ZTunnel, Kiali). Step 0
#           labels the namespace for istiod – that needs cluster-admin (or do it
#           before: admin/namespace-in-mesh.sh).
#  The demo runs in the project "demo-mesh" (or NAME), created if missing.
#
#    0  cluster-admin: the mesh (ambient) is there – the namespace joins its scope
#    1  you: the shop without the mesh – every Pod 1/1
#    2  you: the ambient label in the Pod template – still 1/1, mTLS by ztunnel
#    3  you: a waypoint for L7 – the shop in Kiali with HTTP metrics
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-mesh}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-3); default: all steps
  cleanup                delete the demo objects (the namespace label stays)"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-3]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

cd "${SCRIPT_DIR}" || die "Cannot cd to ${SCRIPT_DIR}"

DEPLOYMENTS="web catalog cart orders review"
LABEL="istio-discovery=enabled"

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

rollouts() {
  local d
  for d in ${DEPLOYMENTS}; do
    oc rollout status "deployment/${d}" --timeout=180s >/dev/null 2>&1 || true
  done
}

# traffic – 30 calls through the Route, as a browser would
TRAFFIC="ROUTE=\$(oc get route web -o jsonpath='{.spec.host}'); for i in \$(seq 1 30); do curl -sk -o /dev/null -w '%{http_code} ' https://\$ROUTE/api/catalog/products; done; echo"

in_scope() {    # the namespace carries the discovery label
  [[ "$(oc get project "${DEMO_PROJECT}" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null)" == enabled ]]
}

kiali_url() {
  local host
  host="$(oc -n istio-system get route kiali -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf "https://%s/console/graph/namespaces/?namespaces=%s" "${host}" "${DEMO_PROJECT}"
  else
    printf "%s  (console: Service Mesh › Traffic Graph, namespace %s)" "$(oc whoami --show-console)" "${DEMO_PROJECT}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -k waypoint --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · cluster-admin: the mesh is there – the namespace joins"
  comment "Installed once by the platform team: control plane, CNI and ztunnel – profile ambient"
  run "oc get istio,istiocni,ztunnel"
  run "oc get istio default -o jsonpath='profile: {.spec.profile}{\"\\n\"}'"
  run "oc -n ztunnel get daemonset 2>/dev/null || oc get daemonset -A | grep -i ztunnel"
  comment "istiod only watches namespaces that match its discoverySelectors"
  run "oc get istio default -o jsonpath='{.spec.values.meshConfig.discoverySelectors}{\"\\n\"}'"
  run "oc get project ${DEMO_PROJECT} --show-labels"
  if in_scope; then
    comment "The namespace has the label already"
  elif [[ "$(oc auth can-i patch namespaces 2>/dev/null)" == yes ]]; then
    run "oc label namespace ${DEMO_PROJECT} ${LABEL}"
  else
    warn "Not allowed to label namespaces – a cluster-admin runs: admin/namespace-in-mesh.sh ${DEMO_PROJECT}"
  fi

  discuss \
    "The platform team's part - done once, not per application" \
    "" \
    "  Operator, Istio + IstioCNI (profile ambient), ZTunnel, Kiali" \
    "  ztunnel: one Pod per node - mTLS and L4 for every ambient Pod" \
    "  which namespaces belong to the mesh: label ${LABEL}" \
    "" \
    "No cluster-admin rights needed for anything that follows."
}

step1() {
  section "1 · you: the shop – without the mesh"
  show_file no-mesh/kustomization.yaml
  run "oc apply -k no-mesh"
  rollouts
  run "oc get pods"

  discuss \
    "Five Deployments, every Pod 1/1" \
    "" \
    "Being in a mesh namespace changes nothing yet:" \
    "on this cluster a workload joins by its own label." \
    "Remember the 1/1 - in ambient mode it stays that way."
}

step2() {
  section "2 · you: the ambient label in the Pod template"
  [[ "${MODE}" == "2" ]] && { oc apply -k no-mesh >/dev/null; rollouts; }
  show_file ambient/kustomization.yaml
  run "oc kustomize ambient | grep -B2 -A1 'istio.io/dataplane-mode'"
  run "oc apply -k ambient"
  rollouts
  comment "Still 1/1 – no sidecar, only the app container"
  run "oc get pods"
  run "oc get pod -l app.kubernetes.io/name=catalog -o jsonpath='{.items[0].spec.containers[*].name}{\"\\n\"}'"
  comment "istio-cni redirects the Pod's traffic to ztunnel – it marks the Pod:"
  run "oc get pod -l app.kubernetes.io/name=catalog -o jsonpath='{.items[0].metadata.annotations.ambient\\.istio\\.io/redirection}{\"\\n\"}'"
  run "${TRAFFIC}"

  discuss \
    "Your part: one label - in the Pod template, in Git" \
    "" \
    "  istio.io/dataplane-mode: ambient   -> 1/1, traffic via ztunnel" \
    "" \
    "mTLS, identity, L4 policies and TCP metrics - nothing in your Pod." \
    "The template change rolled out new Pods; a namespace label" \
    "(platform team) puts running Pods in without a restart."
}

step3() {
  section "3 · you: a waypoint for L7 – the shop in Kiali"
  [[ "${MODE}" == "3" ]] && { oc apply -k ambient >/dev/null; rollouts; }
  show_file waypoint/waypoint.yaml
  run "oc apply -k waypoint"
  run "oc wait --for=condition=Programmed gateway/waypoint --timeout=120s"
  run "oc get gateway waypoint"
  run "oc get pods"
  run "oc get service -L istio.io/use-waypoint"
  run "${TRAFFIC}"
  comment "Open the graph – namespace ${DEMO_PROJECT}, last 5 minutes:"
  run "echo \"$(kiali_url)\""
  pause

  discuss \
    "L7 only where you need it - through the waypoint" \
    "" \
    "  waypoint: one Envoy Deployment for the namespace (Gateway API)" \
    "  Services with istio.io/use-waypoint send their calls through it" \
    "" \
    "HTTP metrics, routing, retries, fault injection, L7 policies" \
    "need the waypoint - without it you get mTLS and TCP metrics."
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
  [0-3])
    "step${MODE}"
    ;;
  all)
    cleanup
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-18 --timeout=90s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 18 – The shop joins the mesh" "cluster-admin · ambient · 1/1 · waypoint · Kiali"
    for i in 0 1 2 3; do "step${i}"; done

    takeaways \
      "The platform team installs the mesh and decides which namespaces belong to it" \
      "You put a workload in: one label in the Pod template – in Git" \
      "Ambient: no sidecar – 1/1, ztunnel does mTLS and L4" \
      "A waypoint adds L7: HTTP metrics, routing, retries, L7 policies"
    ;;
esac
