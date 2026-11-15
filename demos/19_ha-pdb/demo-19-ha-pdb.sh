#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 19 – Spread and PDB at work
#  Run:     ./demo-19-ha-pdb.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; at least 2 worker nodes (3 zones show the zone
#           spread best). Everything runs with namespace rights – listing the
#           nodes and zones in step 1 needs cluster read rights (optional).
#  The demo runs in the project "demo-ha" (or NAME), created if missing.
#
#  catalog and a probe Pod that calls it five times per second ("the users"):
#    0  one replica – deleting the Pod is an outage
#    1  three replicas, spread over nodes and zones
#    2  a PodDisruptionBudget – the second eviction is refused
#    3  a rollout under load – nobody notices
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-ha}"
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

SEL="app.kubernetes.io/name=catalog"

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# answers SINCE – what "the users" got since SINCE: count per HTTP status
answers() {
  oc logs probe --since-time="$1" | awk '{print $2}' | sort | uniq -c
}

# eviction POD – the Eviction object for POD (what oc adm drain sends per Pod)
eviction() {
  printf '{"apiVersion": "policy/v1", "kind": "Eviction", "metadata": {"name": "%s"}}\n' "$1"
}

pods() { oc get pods -l "${SEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

base_state() {
  oc apply -k . >/dev/null
  oc wait --for=condition=Ready pod/probe --timeout=120s >/dev/null 2>&1 || true
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
}

ha_state() {
  oc patch deployment catalog --patch-file spread.yaml >/dev/null
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f pdb.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete -k . --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · One replica – a restart is an outage"
  run "oc apply -k ."
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc wait --for=condition=Ready pod/probe --timeout=120s"
  comment "The users: five calls per second – time and HTTP status"
  run "oc logs probe --tail=5"
  T0="$(now)"
  comment "Something deletes the Pod – a node drain, an eviction, a crash"
  run "oc delete pod -l ${SEL} --wait=false"
  run "oc rollout status deployment/catalog --timeout=180s"
  sleep 5
  comment "What the users got since the delete (000 = no answer):"
  run "answers ${T0}"

  discuss \
    "One replica - every Pod restart is a short outage" \
    "" \
    "A new Pod has to be scheduled, pulled, started and become ready." \
    "Meanwhile the Service has no endpoint: 000 or 503 for the users."
}

step1() {
  section "1 · Three replicas – spread over nodes and zones"
  [[ "${MODE}" == "1" ]] && base_state
  show_file spread.yaml
  run "oc patch deployment catalog --patch-file spread.yaml"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc get pods -l ${SEL} -o wide"
  if [[ "$(oc auth can-i list nodes 2>/dev/null)" == yes ]]; then
    comment "The zones of the nodes (needs cluster read rights)"
    run "oc get nodes -l node-role.kubernetes.io/worker -L topology.kubernetes.io/zone"
  fi

  discuss \
    "Spread: replicas on different nodes - and zones" \
    "" \
    "  hostname  DoNotSchedule   never two more on one node than elsewhere" \
    "  zone      ScheduleAnyway  prefer different zones" \
    "" \
    "Three replicas on one node die together with that node."
}

step2() {
  section "2 · A PodDisruptionBudget – the second eviction is refused"
  [[ "${MODE}" == "2" ]] && { base_state; ha_state; }
  show_file pdb.yaml
  run "oc apply -f pdb.yaml"
  run "oc get pdb catalog"
  read -r P1 P2 _ <<<"$(pods | tr '\n' ' ')"
  comment "oc adm drain sends one Eviction per Pod – we send two by hand:"
  run "eviction ${P1}"
  run "oc create --raw /api/v1/namespaces/${DEMO_PROJECT}/pods/${P1}/eviction -f <(eviction ${P1})"
  run "oc create --raw /api/v1/namespaces/${DEMO_PROJECT}/pods/${P2}/eviction -f <(eviction ${P2})"
  run "oc get pdb catalog"
  run "oc get pods -l ${SEL}"
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true

  discuss \
    "The PDB is asked - by every voluntary disruption" \
    "" \
    "First eviction: ok (3 -> 2, minAvailable 2 still holds)." \
    "Second one: 429 - 'would violate the pod's disruption budget'." \
    "oc adm drain retries until the replacement Pod is ready." \
    "" \
    "No protection against crashes or a lost node - that is what spread is for." \
    "minAvailable = replicas blocks every drain - the platform team hates that."
}

step3() {
  section "3 · A rollout under load – nobody notices"
  [[ "${MODE}" == "3" ]] && { base_state; ha_state; oc apply -f pdb.yaml >/dev/null; }
  comment "maxSurge 1, maxUnavailable 0, readiness probe and a 5 s preStop (spread.yaml)"
  T0="$(now)"
  run "oc rollout restart deployment/catalog"
  run "oc rollout status deployment/catalog --timeout=300s"
  sleep 3
  comment "What the users got during the rollout:"
  run "answers ${T0}"

  discuss \
    "Zero errors - four settings together" \
    "" \
    "  maxUnavailable 0   a new Pod first, then an old one goes" \
    "  readiness probe    traffic only to Pods that are ready" \
    "  preStop sleep      the old Pod serves until the endpoints are updated" \
    "  replicas >= 2      somebody always answers"
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
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-19 --timeout=90s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 19 – Spread and PDB at work" "one replica · spread · PDB · rollout under load"
    for i in 0 1 2 3; do "step${i}"; done

    takeaways \
      "One replica means: every restart is an outage" \
      "Spread the replicas over nodes and zones" \
      "A PDB protects against drains – not against crashes" \
      "maxUnavailable 0 + readiness + preStop: rollouts nobody notices"
    ;;
esac
