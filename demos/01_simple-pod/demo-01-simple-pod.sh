#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 01 – Simple Pods
#  Run:     ./demo-01-simple-pod.sh [-n|--namespace NAME]
#  Expects: oc logged in
#  The demo runs in the project "demo" (or NAME), created if missing.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
parse_demo_args "$@"
cd "${SCRIPT_DIR}"

UBI_IMAGE="registry.redhat.io/ubi9/ubi:9.9"

# securityContext for "oc run" that satisfies the PodSecurity "restricted" profile
OVERRIDES_FILE="ubi-security-overrides.yaml"
YQ_CMD="$(yq_to_json_cmd "${OVERRIDES_FILE}")"
if [[ -n "${YQ_CMD}" ]]; then
  # shown as-is in the demo: readable and copy-pasteable
  OVERRIDES_ARG="\"\$(${YQ_CMD})\""
else
  # no yq: convert once and show the resulting JSON
  OVERRIDES_ARG="'$(yaml_to_json "${OVERRIDES_FILE}")'"
fi

cleanup() {
  delete_quietly pod ubi simple-pod advanced-pod
}

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login
cleanup
on_exit_cleanup cleanup "Delete the demo pods? [y/N]"

# ═══════════════════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════════════════
title "Demo 01 – Simple Pods" "oc run · PodSecurity · pod YAML · multi-container"

# ── 1 · Where am I? ────────────────────────────────────────────────────────
section "1 · Check your current project"

comment "Always check which project (namespace) you are working in"
run "oc project"

# ── 2 · Pod from the command line ──────────────────────────────────────────
section "2 · Create a pod from the command line"

comment "Start an interactive pod. Type 'exit' to leave the shell."
info "  -i / -t          interactive, allocate a terminal"
info "  --restart=Never  create a plain Pod, do not restart it"
info "  --rm             delete the pod when the shell exits"
run "oc run -i -t ubi --image=${UBI_IMAGE} --restart=Never --rm"

# ── 3 · The PodSecurity warning ────────────────────────────────────────────
section "3 · What was that 'PodSecurity' warning?"

discuss \
  "Warning: would violate PodSecurity \"restricted:latest\"" \
  "" \
  "Pod Security Admission (PSA) is the standard Kubernetes check." \
  "OpenShift labels every new project with warn/audit=restricted," \
  "so pods missing these settings produce a WARNING:" \
  "  - allowPrivilegeEscalation: false" \
  "  - capabilities.drop: [\"ALL\"]" \
  "  - runAsNonRoot: true" \
  "  - seccompProfile.type: RuntimeDefault" \
  "" \
  "It is only a warning: nothing is enforced by PSA (no 'enforce'" \
  "label). OpenShift's SCC 'restricted-v2' admits the pod and" \
  "fills in secure values (non-root UID, no capabilities, ...)."

comment "The PSA labels OpenShift put on our project"
run "oc get namespace ${DEMO_PROJECT} -o yaml"

discuss \
  "pod-security.kubernetes.io/<MODE>=<LEVEL>" \
  "" \
  "MODE   enforce  reject pods that violate the level" \
  "       audit    allow, but record the violation in the audit log" \
  "       warn     allow, but return a warning to the user (we saw it)" \
  "LEVEL  privileged  no restrictions" \
  "       baseline    blocks known escalations (privileged, hostPath," \
  "                   hostNetwork, hostPID, added capabilities, ...)" \
  "       restricted  baseline + hardening (non-root, drop ALL, ...)" \
  "<MODE>-version  pin the rules to a Kubernetes version (v1.33)" \
  "                or 'latest'" \
  "" \
  "OpenShift sets audit/warn automatically from the SCCs the project's" \
  "service accounts may use (label syncer). enforce is cluster-wide" \
  "'privileged' today - SCCs do the enforcing. Changing the labels" \
  "requires cluster-admin rights."

comment "The fix: set the four fields explicitly. As readable YAML:"
show_file "${OVERRIDES_FILE}"
pause

comment "--overrides expects JSON, so we convert the YAML on the fly"
comment "--override-type=strategic merges it into the generated pod (containers by name)"
run "oc run -i -t ubi --image=${UBI_IMAGE} --restart=Never --override-type=strategic --overrides=${OVERRIDES_ARG}"

comment "No warning this time. And without --rm the pod still exists ('Completed')"
run "oc get pods"

comment "Delete it manually"
run "oc delete pod ubi"

# ── 4 · Pod from YAML ──────────────────────────────────────────────────────
section "4 · Create a pod from a YAML file"

comment "Note the securityContext – pod level AND container level"
show_file simple-pod.yml
pause

comment "Create the pod from the file – no PodSecurity warning"
run "oc create -f simple-pod.yml"

comment "Wait until the pod is ready"
run "oc wait --for=condition=Ready pod/simple-pod --timeout=120s"

run "oc get pods -o wide"

comment "runAsNonRoot works because the SCC assigns a UID from the project's range"
run "oc exec simple-pod -- id"

# ── 5 · Multi-container pod ────────────────────────────────────────────────
section "5 · A pod running two containers"

show_file advanced-pod.yml
pause

run "oc create -f advanced-pod.yml"
run "oc wait --for=condition=Ready pod/advanced-pod --timeout=120s"

comment "READY shows 2/2 – two containers in one pod"
run "oc get pods"

comment "Without a container name, oc logs picks the default container"
run "oc logs advanced-pod"

comment "Select a container with -c"
run "oc logs -c container1 advanced-pod"
run "oc logs -c container2 advanced-pod"

comment "Both containers share the pod's network – same IP, same hostname"
run "oc exec advanced-pod -c container1 -- cat /etc/hostname"
run "oc exec advanced-pod -c container2 -- cat /etc/hostname"

comment "requests == limits for every container -> QoS class 'Guaranteed'"
run "oc get pod advanced-pod -o jsonpath='{.status.qosClass}{\"\\n\"}'"
comment "simple-pod has no resources at all -> 'BestEffort'"
run "oc get pod simple-pod -o jsonpath='{.status.qosClass}{\"\\n\"}'"

discuss \
  "Why put two containers into one pod?" \
  "" \
  "Containers in a pod are scheduled together and share" \
  "network (localhost) and, optionally, volumes." \
  "Typical use: sidecars (proxy, log shipper), init containers." \
  "" \
  "Requests: what the scheduler reserves for the container" \
  "Limits:   the hard ceiling (CPU throttled, memory -> OOMKill)" \
  "QoS:      Guaranteed > Burstable > BestEffort (eviction order)"

takeaways \
  "Check your project before creating anything (oc project)" \
  "oc run is quick but imperative – YAML is reproducible" \
  "A pod can run several containers sharing network and volumes" \
  "PodSecurity warnings: set the securityContext explicitly" \
  "Use 'oc logs -c <container>' with multi-container pods" \
  "Requests/limits decide scheduling and the QoS class"
