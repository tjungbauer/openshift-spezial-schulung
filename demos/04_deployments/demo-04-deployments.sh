#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 04 – Deployments
#  Run:     ./demo-04-deployments.sh
#  Expects: oc logged in (project "demo" is created if missing)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
cd "${SCRIPT_DIR}"

DEPLOY="nginx-deployment"
SELECTOR="app=nginx,${DEMO_LABEL}"

cleanup() {
  delete_quietly deployment "${DEPLOY}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login
cleanup
on_exit_cleanup cleanup "Delete the nginx deployment? [y/N]"

# ═══════════════════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════════════════
title "Demo 04 – Deployments" "self-healing · scaling · rollout · rollback"

# ── 1 · Deploy nginx ───────────────────────────────────────────────────────
section "1 · Deploy nginx"

show_file nginx-deployment.yml
pause

run "oc apply -f nginx-deployment.yml"
run "oc rollout status deployment/${DEPLOY} --timeout=120s"

comment "Which resources were created?"
run "oc get deployment,replicaset,pod -l ${SELECTOR}"

comment "Who owns the pod? -> the ReplicaSet"
run "oc get pods -l ${SELECTOR} -o jsonpath='{range .items[*]}{.metadata.name} -> {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{\"\\n\"}{end}'"

discuss \
  "Deployment -> ReplicaSet -> Pod" \
  "" \
  "Deployment:  desired state + rollout strategy" \
  "ReplicaSet:  keeps exactly N pods with a given template" \
  "Pod:         the running containers" \
  "" \
  "You manage the Deployment – the rest is created for you."

# ── 2 · Delete the pod ─────────────────────────────────────────────────────
section "2 · What happens if the pod is deleted?"

run "oc get pods -l ${SELECTOR}"
run "oc delete pods -l ${SELECTOR}"

comment "A new pod (with a new name) is already there"
run "oc get pods -l ${SELECTOR}"

discuss \
  "Self-healing" \
  "" \
  "The ReplicaSet controller constantly compares" \
  "desired (replicas: 1) with actual (0 pods) state" \
  "and creates a replacement pod immediately." \
  "" \
  "Pods are cattle, not pets: never rely on a pod name or IP."

# ── 3 · Scale ──────────────────────────────────────────────────────────────
section "3 · Scale the deployment to two replicas"

run "oc scale --replicas=2 deployment/${DEPLOY}"
run "oc rollout status deployment/${DEPLOY} --timeout=120s"

#comment "What is the state of the ReplicaSet now?"
#run "oc get replicaset -l ${SELECTOR}"

comment "How many pods are running?"
run "oc get pods -l ${SELECTOR} -o wide"

comment "'oc scale' changed the live object – the YAML file still says 1 (exit code 1 = differences found)"
run "oc diff -f nginx-deployment.yml"

# ── 4 · Rolling update & rollback ──────────────────────────────────────────
section "4 · Rolling update and rollback"

comment "Any change to the pod template triggers a new rollout"
run "oc set env deployment/${DEPLOY} DEMO_VERSION=v2"
run "oc rollout status deployment/${DEPLOY} --timeout=120s"

comment "There are two ReplicaSets now – the old one is scaled to 0"
run "oc get replicaset -l ${SELECTOR}"
run "oc rollout history deployment/${DEPLOY}"

comment "Go back to the previous revision"
run "oc rollout undo deployment/${DEPLOY}"
run "oc rollout status deployment/${DEPLOY} --timeout=120s"
run "oc get replicaset -l ${SELECTOR}"

discuss \
  "Rollouts" \
  "" \
  "Strategy RollingUpdate (default): new pods start before" \
  "old ones are stopped -> no downtime." \
  "" \
  "Old ReplicaSets are kept (revisionHistoryLimit) so that" \
  "'oc rollout undo' can switch back instantly."

takeaways \
  "Deployments manage ReplicaSets, ReplicaSets manage pods" \
  "Deleted pods are replaced automatically (self-healing)" \
  "oc scale changes the replica count of the live object" \
  "Template changes roll out; oc rollout undo rolls back" \
  "Deleting a Deployment removes its ReplicaSets and pods"
