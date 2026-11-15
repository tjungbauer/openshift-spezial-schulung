#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 15 – Requests, limits and the HPA
#  Run:     ./demo-15-resources-hpa.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; cluster metrics (oc adm top) available
#  The demo runs in the project "demo-resources" (or NAME), created if missing.
#
#  Two copies of the shop's catalog service – without and with a CPU limit –,
#  load generator Deployments (curl loops) and a client Pod that measures latency.
#    0  requests vs. real usage
#    1  a tight CPU limit: throttling, latency goes up
#    2  the HPA scales out under load
#    3  load stops – scale-in waits for the stabilisation window
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-resources}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-3); default: all steps
  cleanup                delete the demo objects"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-3]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

cd "${SCRIPT_DIR}" || die "Cannot cd to ${SCRIPT_DIR}"
SEL="app.kubernetes.io/name in (catalog,catalog-limited)"

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers – used in the commands of the demo
# ═══════════════════════════════════════════════════════════════════════════

# latency SERVICE – 20 calls from the client Pod, average response time
latency() {
  oc exec client -- sh -c \
    "for i in \$(seq 20); do curl -s -o /dev/null -m 10 -w '%{time_total}\n' http://$1:8080/products; done" \
    | awk -v svc="$1" '{s+=$1; if ($1>m) m=$1} END {printf "%-16s avg %4.0f ms   max %4.0f ms   (%d calls)\n", svc, s/NR*1000, m*1000, NR}'
}

# requests – what each Pod asked for
requests() {
  oc get pods -l "${SEL}" -o custom-columns='POD:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,MEM_LIM:.spec.containers[0].resources.limits.memory,QOS:.status.qosClass'
}

hpa_replicas() {
  oc get hpa catalog -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0
}

promql() {   # print a query to paste into Observe › Metrics
  printf "%s   Observe › Metrics:%s\n   %s\n" "${C_DIM}" "${C_RESET}" "$1"
}

base_state() {   # for single steps
  oc apply -f client.yaml -f catalog.yaml -f load.yaml >/dev/null
  oc wait --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1 || true
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
  oc rollout status deployment/catalog-limited --timeout=180s >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f hpa.yaml -f load.yaml -f catalog.yaml -f client.yaml \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · Requests vs. real usage"

  show_file catalog.yaml
  run "oc apply -f client.yaml -f catalog.yaml -f load.yaml"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc rollout status deployment/catalog-limited --timeout=180s"
  run "oc wait --for=condition=Ready pod/client --timeout=120s"
  comment "What the Pods asked for – requests reserve, limits cap"
  run "requests"
  comment "What they really use (metrics need about a minute for new Pods)"
  wait_until "Pod metrics" 120 "oc adm top pods -l app.kubernetes.io/name=catalog | grep -q catalog" || true
  run "oc adm top pods -l '${SEL}'"
  promql "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"${DEMO_PROJECT}\",container=\"catalog\"}[2m]))"
  pause

  discuss \
    "Requests are a reservation - not a measurement" \
    "" \
    "  request   the scheduler reserves it on a node - always" \
    "  limit     the kernel enforces it: CPU throttled, memory OOMKilled" \
    "  usage     what the app really needs - measure it, then size" \
    "" \
    "Idle catalog: a few millicores. Requested: 50m." \
    "QoS Burstable: requests set, limits higher or missing."
}

step1() {
  section "1 · A tight CPU limit – throttling"
  [[ "${MODE}" == "1" ]] && base_state

  comment "Without load: both answer equally fast"
  run "latency catalog; latency catalog-limited"
  comment "Same load on both: one load Pod each, 4 parallel curl loops"
  show_file load.yaml
  run "oc scale deployment/load-catalog deployment/load-limited --replicas=1"
  run "oc rollout status deployment/load-catalog --timeout=120s"
  run "oc rollout status deployment/load-limited --timeout=120s"
  info "   60 s of load – the metrics need a moment to catch up ..."
  sleep 60
  run "oc adm top pods -l '${SEL}'"
  run "latency catalog; latency catalog-limited"
  promql "sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace=\"${DEMO_PROJECT}\",container=\"catalog\"}[2m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace=\"${DEMO_PROJECT}\",container=\"catalog\"}[2m]))"
  pause

  run "oc scale deployment/load-catalog deployment/load-limited --replicas=0"

  discuss \
    "A CPU limit does not kill - it slows down" \
    "" \
    "50m = 5 ms CPU per 100 ms period. Used up? Wait for the next period." \
    "oc adm top: catalog-limited sticks at ~50m, catalog takes what" \
    "the node has spare. Latency of the limited one goes up." \
    "" \
    "The throttling ratio (PromQL above) shows it - top does not." \
    "Memory is different: over the limit = OOMKilled (exit code 137)."
}

step2() {
  section "2 · The HPA scales out under load"
  [[ "${MODE}" == "2" ]] && base_state

  show_file hpa.yaml
  run "oc apply -f hpa.yaml"
  wait_until "the HPA reads metrics" 90 \
    "oc get hpa catalog -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -q '[0-9]'" || true
  run "oc get hpa catalog"
  comment "Three load Pods = 12 parallel curl loops against catalog"
  run "oc scale deployment/load-catalog --replicas=3"
  wait_until "the HPA adds replicas" 240 "[[ \$(hpa_replicas) -ge 2 ]]" || true
  run "oc get hpa catalog"
  wait_until "more replicas ready" 120 \
    "[[ \$(oc get deployment catalog -o jsonpath='{.status.readyReplicas}') -ge 2 ]]" || true
  run "oc get pods -l app.kubernetes.io/name=catalog"
  run "oc adm top pods -l app.kubernetes.io/name=catalog"
  run "latency catalog"
  run "oc describe hpa catalog | sed -n '/Events:/,\$p'"

  discuss \
    "HPA: utilisation = usage / request" \
    "" \
    "Target 60 % of 50m = 30m per Pod. Above -> more replicas:" \
    "  desired = ceil(current replicas x current / target)" \
    "" \
    "No CPU request - no utilisation - no HPA." \
    "Scale-out reacts within seconds; the new Pods must still start" \
    "- a fast startup and a good readiness probe matter (demo 14)."
}

step3() {
  section "3 · Load stops – scale-in waits"
  [[ "${MODE}" == "3" ]] && base_state
  [[ "${MODE}" == "3" ]] && oc apply -f hpa.yaml >/dev/null

  run "oc scale deployment/load-catalog --replicas=0"
  wait_until "CPU drops below the target" 120 \
    "[[ \$(oc get hpa catalog -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}') -lt 60 ]]" || true
  run "oc get hpa catalog"
  comment "Utilisation is low – but the replicas stay: stabilizationWindowSeconds: 120"
  run "oc get pods -l app.kubernetes.io/name=catalog"
  wait_until "the HPA scales in (after the window)" 300 "[[ \$(hpa_replicas) -le 1 ]]" || true
  run "oc get hpa catalog"
  run "oc describe hpa catalog | sed -n '/Events:/,\$p'"

  discuss \
    "Scale out fast, scale in slowly" \
    "" \
    "The HPA uses the highest recommendation of the last window" \
    "(default 300 s) - short dips in load do not remove Pods." \
    "" \
    "With GitOps: do not set replicas in Git for an HPA target -" \
    "or ignore spec.replicas in Argo CD (module 05)."
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
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-15 --timeout=60s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 15 – Requests, limits and the HPA" "requests · usage · CPU limit · throttling · HPA"
    for i in 0 1 2 3; do "step${i}"; done

    takeaways \
      "Requests reserve capacity – measure the real usage before you size them" \
      "A CPU limit throttles: the app gets slower, not killed" \
      "Memory over the limit is OOMKilled – size memory limits with care" \
      "The HPA needs CPU requests – utilisation is usage divided by request" \
      "Scale out fast, scale in slowly – the stabilisation window"
    ;;
esac
