#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 03 – ConfigMaps & Secrets
#  Run:     ./demo-03-configmaps-secrets.sh
#  Expects: oc logged in (project "demo" is created if missing)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
cd "${SCRIPT_DIR}"

cleanup() {
  delete_quietly pod not-so-simple-pod
  delete_quietly configmap run config podenv
  delete_quietly secret geheim
}

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login
cleanup
on_exit_cleanup cleanup "Delete the demo pod, configmaps and secret? [y/N]"

# ═══════════════════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════════════════
title "Demo 03 – ConfigMaps & Secrets" "env vars · mounted files · live updates"

# ── 1 · The input files ────────────────────────────────────────────────────
section "1 · The files we want to put into the cluster"

comment "A start script for our container ..."
show_file run.sh
comment "... and two configuration files"
show_file mainconfig.yml
show_file anotherconfig.yml
pause

# ── 2 · ConfigMaps ─────────────────────────────────────────────────────────
section "2 · Create ConfigMaps"

comment "From a file – the key is the file name (run.sh)"
run "oc create configmap run --from-file=run.sh"

comment "From two files – 'configuration=' sets a custom key name"
run "oc create configmap config --from-file=configuration=mainconfig.yml --from-file=anotherconfig.yml"

comment "From a literal key=value"
run "oc create configmap podenv --from-literal=variable=myvalue"

comment "Label them, so they are easier to find"
run "oc label configmap run config podenv ${DEMO_LABEL}"

run "oc get configmaps -l ${DEMO_LABEL}"

comment "Look at the keys: 'configuration' and 'anotherconfig.yml'"
run "oc describe configmap config"

# ── 3 · Secrets ────────────────────────────────────────────────────────────
section "3 · Create a Secret"

run "oc create secret generic geheim --from-literal=secret=nobody_knows"
run "oc label secret geheim ${DEMO_LABEL}"

comment "The value is stored base64 encoded ..."
run "oc get secret geheim -o yaml"

comment "... which is NOT encryption"
run "oc get secret geheim -o jsonpath='{.data.secret}' | base64 -d; echo"

discuss \
  "Secrets are base64 – not encrypted" \
  "" \
  "Anyone who may read the Secret can decode it." \
  "Protection comes from:" \
  "  - RBAC (who may 'get' secrets)" \
  "  - etcd encryption at rest (cluster setting)" \
  "  - external tools: Sealed Secrets, External Secrets, Vault" \
  "" \
  "Never commit plain Secret YAML to Git."

# ── 4 · Use them in a pod ──────────────────────────────────────────────────
section "5 · Use ConfigMaps and Secrets in a pod"

show_file not-so-simple-pod.yml
pause

discuss \
  "What does this pod do?" \
  "" \
  "env VARIABLE   <- configmap podenv, key 'variable'" \
  "env SECRET     <- secret geheim,   key 'secret'" \
  "" \
  "/usr/local/bin <- configmap run    (run.sh = the command)" \
  "/etc/test      <- configmap config, ONLY key 'configuration'" \
  "                  mounted as config.yml" \
  "" \
  "anotherconfig.yml is in the configmap but NOT mounted."

run "oc apply -f not-so-simple-pod.yml"
run "oc wait --for=condition=Ready pod/not-so-simple-pod --timeout=120s"

comment "run.sh prints the config file and both variables every second"
run "oc logs --tail=6 not-so-simple-pod"

comment "What is mounted inside the container?"
run "oc exec not-so-simple-pod -- ls -l /etc/test/ /usr/local/bin/"
run "oc exec not-so-simple-pod -- env | grep -E '^(VARIABLE|SECRET)='"

# ── 6 · Live updates ───────────────────────────────────────────────────────
section "6 · What happens when a ConfigMap changes?"

comment "Change the mounted config file AND the environment variable"
run "oc patch configmap config --type merge -p '{\"data\":{\"configuration\":\"name: example\\nversion: 0.9.9\\n\"}}'"
run "oc patch configmap podenv --type merge -p '{\"data\":{\"variable\":\"changed\"}}'"

comment "The kubelet syncs mounted ConfigMaps periodically (up to ~1 minute)"
wait_until "new config file inside the pod" 120 \
  "oc exec not-so-simple-pod -- grep -q 0.9.9 /etc/test/config.yml" || true

run "oc logs --tail=6 not-so-simple-pod"

discuss \
  "Files update – environment variables do not" \
  "" \
  "Mounted ConfigMaps/Secrets are updated in the running pod" \
  "(not when mounted with subPath!)." \
  "" \
  "Environment variables are set once, when the container" \
  "starts. VARIABLE still shows 'myvalue'." \
  "" \
  "-> restart the pod (or roll out the Deployment) to pick" \
  "   up changed environment variables."

takeaways \
  "ConfigMaps hold configuration, Secrets hold sensitive data" \
  "Both can be used as environment variables or mounted files" \
  "Secrets are only base64 encoded – protect them with RBAC" \
  "--dry-run=client -o yaml generates manifests from oc create" \
  "Mounted files update live, environment variables need a restart"
