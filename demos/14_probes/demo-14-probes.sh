#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 14 – Probes at work
#  Run:     ./demo-14-probes.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in
#  The demo runs in the project "demo-probes" (or NAME), created if missing.
#
#  The catalog service of the shop on its own (2 replicas) plus a curl Pod.
#  Four faults, four different reactions:
#    1  fail_ready         the Pod leaves the Service – no restart
#    2  a slow start       the startup probe holds the other probes back
#    3  a wrong liveness   a healthy container is restarted
#    4  a broken image     the rollout stops, the old Pods keep serving
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-probes}"
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
SEL="app.kubernetes.io/name=catalog"
BROKEN_IMAGE="quay.io/tjungbau/shop-catalog-dev:does-not-exist"

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers – the commands shown in the demo use the same ones
# ═══════════════════════════════════════════════════════════════════════════

# endpoints – which catalog Pods the Service sends traffic to (EndpointSlice)
endpoints() {
  oc get endpointslice -l kubernetes.io/service-name=catalog \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ready="}{.conditions.ready}{"\n"}{end}'
}

# calls – six requests through the Service; /info names the Pod that answered
calls() {
  oc exec client -- sh -c \
    'for i in 1 2 3 4 5 6; do curl -s -m 3 http://catalog:8080/info || echo "no answer"; echo; done'
}

# fault POD JSON – switch a fault on one Pod (POST /admin/fault, straight to the Pod IP)
fault() {
  local ip
  ip="$(oc get pod "$1" -o jsonpath='{.status.podIP}')"
  oc exec client -- curl -s -m 5 -X POST "http://${ip}:8080/admin/fault" \
    -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' -d "$2"
  echo
}

restarts() {   # restarts DEPLOYMENT-NAME-LABEL – sum of the container restarts
  oc get pods -l "app.kubernetes.io/name=$1" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    | awk '{s+=$1} END {print s+0}'
}

ready_pods() {
  oc get pods -l "$1" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c true || true
}

base_state() {   # catalog and the client exist and are ready (for single steps)
  oc apply -f client.yaml -f catalog.yaml >/dev/null
  oc wait --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1 || true
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f slow-start.yaml -f catalog.yaml -f client.yaml \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · The starting point – catalog with three probes"

  show_file catalog.yaml
  run "oc apply -f client.yaml -f catalog.yaml"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc wait --for=condition=Ready pod/client --timeout=120s"
  run "oc get pods -l ${SEL} -o wide"
  comment "Which Pods does the Service use? (EndpointSlice – ready=true means: gets traffic)"
  run "endpoints"
  comment "Six calls through the Service – 'pod' tells who answered"
  run "calls"

  discuss \
    "Three probes, three questions" \
    "" \
    "  startup     has it started?      until then the other two wait" \
    "  readiness   can it serve now?    no -> out of the Service" \
    "  liveness    is it stuck?         no -> container restart" \
    "" \
    "The kubelet asks - the answer decides what happens to the Pod."
}

step1() {
  section "1 · Unready, not dead – fail_ready on one Pod"
  [[ "${MODE}" == "1" ]] && base_state

  run "POD=\$(oc get pods -l ${SEL} -o jsonpath='{.items[0].metadata.name}'); echo \$POD"
  comment "POST /admin/fault – the Pod now answers /health/ready with 503"
  run "fault \$POD '{\"fail_ready\": true}'"
  wait_until "the kubelet marks the Pod not ready" 60 \
    "[[ \$(oc get pod \$POD -o jsonpath='{.status.containerStatuses[0].ready}') == false ]]" || true
  run "oc get pods -l ${SEL}"
  run "endpoints"
  comment "All calls now go to the other Pod – nobody gets an error"
  run "calls"
  run "oc get events --field-selector involvedObject.name=\$POD | grep -i readiness | tail -3"
  pause

  comment "Fault off – the Pod comes back into the Service by itself"
  run "fault \$POD '{\"fail_ready\": false}'"
  wait_until "the Pod ready again" 60 \
    "[[ \$(oc get pod \$POD -o jsonpath='{.status.containerStatuses[0].ready}') == true ]]" || true
  run "oc get pods -l ${SEL}"
  run "endpoints"

  discuss \
    "Readiness: out of the Service - not restarted" \
    "" \
    "READY 0/1, RESTARTS 0. The Service skips the Pod, the other" \
    "replica takes all calls. Back to ready = back in the Service." \
    "" \
    "Use it for: warming up, overload, a dependency that is down." \
    "With ONE replica, unready means: the Service has no endpoint."
}

step2() {
  section "2 · A slow start – the startup probe holds the others back"
  [[ "${MODE}" == "2" ]] && base_state

  comment "The same app, 40 s to start – once with, once without a startup probe"
  show_file slow-start.yaml
  run "oc apply -f slow-start.yaml"
  run "oc get pods -l app.kubernetes.io/part-of=demo-14"
  wait_until "slow-with-startup ready (~40 s)" 120 \
    "[[ \$(ready_pods app.kubernetes.io/name=slow-with-startup) -ge 1 ]]" || true
  wait_until "slow-no-startup restarted at least once" 90 \
    "[[ \$(restarts slow-no-startup) -ge 1 ]]" || true
  run "oc get pods -l 'app.kubernetes.io/name in (slow-with-startup,slow-no-startup)'"
  comment "with startup probe: it failed for 40 s – and nothing else happened"
  run "oc get events --field-selector reason=Unhealthy | grep slow-with-startup | tail -3"
  comment "without: liveness asked /health/ready during the start – killed, started again, killed …"
  run "oc get events --field-selector reason=Unhealthy | grep slow-no-startup | tail -3"
  run "oc get events --field-selector reason=Killing | grep slow-no-startup | tail -2"

  discuss \
    "A startup probe protects slow starters" \
    "" \
    "  with startup probe   0/1 for 40 s, then 1/1 - zero restarts" \
    "  without              liveness fails while starting -> restart" \
    "                       -> the start begins again -> CrashLoopBackOff" \
    "" \
    "Budget = failureThreshold x periodSeconds (here 30 x 2 s = 60 s)." \
    "And never let liveness ask 'ready?' - that is readiness' job."
  oc delete -f slow-start.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

step3() {
  section "3 · A wrong liveness probe – a healthy container is restarted"
  [[ "${MODE}" == "3" ]] && base_state

  comment "A typo in the liveness path: /health/livez – the app answers 404"
  run "oc patch deployment catalog --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/httpGet/path\",\"value\":\"/health/livez\"}]'"
  run "oc rollout status deployment/catalog --timeout=120s"
  comment "Ready, serving – and in ~30 s (3 x 10 s) the kubelet kills it anyway"
  wait_until "the first liveness restart" 120 "[[ \$(restarts catalog) -ge 1 ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc get events --field-selector reason=Unhealthy | grep -i liveness | tail -3"
  run "oc get events --field-selector reason=Killing | tail -2"
  comment "The app itself was fine all the time:"
  run "calls"
  pause

  comment "Fix the path – a new rollout, restarts back to 0"
  run "oc patch deployment catalog --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/httpGet/path\",\"value\":\"/health/live\"}]'"
  run "oc rollout status deployment/catalog --timeout=120s"
  run "oc get pods -l ${SEL}"

  discuss \
    "Liveness = the most dangerous probe" \
    "" \
    "A wrong path, a too short timeout, a check of the database:" \
    "the kubelet restarts a healthy container - again and again." \
    "" \
    "Liveness checks only: is THIS process stuck?" \
    "Never a dependency - a restart does not fix the database."
}

step4() {
  section "4 · A broken image – the rollout stops, the old Pods keep serving"
  [[ "${MODE}" == "4" ]] && base_state

  run "oc set image deployment/catalog catalog=${BROKEN_IMAGE}"
  wait_until "the new Pod fails to pull" 60 \
    "oc get pods -l ${SEL} | grep -qE 'ErrImagePull|ImagePullBackOff'" || true
  run "oc get pods -l ${SEL}"
  comment "maxUnavailable 25 % of 2 = 0: no old Pod is stopped before a new one is ready"
  run "calls"

  discuss \
    "Readiness gates every rollout" \
    "" \
    "A new Pod must be READY before an old one stops." \
    "Broken image, crash, failing readiness - the rollout waits," \
    "the users keep the old version." \
    "" \
    "ProgressDeadlineExceeded is the signal for alerts and pipelines" \
    "(default deadline 600 s - here 60 s for the demo)."
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
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-14 --timeout=60s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 14 – Probes at work" "readiness · startup · liveness · rollout"
    for i in 0 1 2 3 4; do "step${i}"; done

    takeaways \
      "Readiness takes a Pod out of the Service – it does not restart it" \
      "A startup probe gives slow starters time – the other probes wait" \
      "Liveness restarts – keep it simple, never check dependencies" \
      "A rollout only continues when new Pods are ready – old ones keep serving" \
      "ProgressDeadlineExceeded tells you a rollout is stuck"
    ;;
esac
