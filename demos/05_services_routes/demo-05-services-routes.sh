#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 05 – Services & Routes
#  Run:     ./demo-05-services-routes.sh
#  Expects: oc logged in (project "demo" is created if missing), curl
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
cd "${SCRIPT_DIR}"

DEPLOY="nginx-deployment"
SELECTOR="app=nginx,${DEMO_LABEL}"
PORT="80$((RANDOM % 89 + 10))"
PF_PID=""

stop_port_forward() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
    PF_PID=""
  fi
}

cleanup() {
  delete_quietly route nginx nginx-ssl
  delete_quietly service nginx
  delete_quietly pod curl-pod
  delete_quietly deployment "${DEPLOY}"
  delete_quietly configmap index
}

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
require_cmd curl
require_oc_login
cleanup
on_exit_cleanup cleanup "Delete all demo resources (deployment, service, routes, ...)? [y/N]"
on_exit_always stop_port_forward

# ═══════════════════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════════════════
title "Demo 05 – Services & Routes" "port-forward · service · route · edge TLS"

# ── 1 · ConfigMap with our web page ────────────────────────────────────────
section "1 · Create a ConfigMap from index.html"

show_file index.html

run "oc create configmap index --from-file=index.html"
run "oc label configmap index ${DEMO_LABEL}"

# ── 2 · Deployment ─────────────────────────────────────────────────────────
section "2 · Deploy nginx serving the ConfigMap"

show_file nginx-deployment-cm.yml
pause

run "oc apply -f nginx-deployment-cm.yml"
run "oc rollout status deployment/${DEPLOY} --timeout=120s"

#comment "What kind of resources were created?"
#run "oc get deployment,replicaset,pod -l ${SELECTOR}"

# ── 3 · Port-forward ───────────────────────────────────────────────────────
section "3 · Test with oc port-forward"

comment "Forward local port ${PORT} to port 8080 of the pod (in the background)"
run "oc port-forward deployment/${DEPLOY} ${PORT}:8080 >/dev/null 2>&1 &"
PF_PID=$!
wait_until "port-forward on localhost:${PORT}" 20 "curl -fs localhost:${PORT}" || true

run "curl -s localhost:${PORT}"

comment "Stop the port-forward"
stop_port_forward
success "port-forward stopped"

discuss \
  "oc port-forward" \
  "" \
  "Tunnels a local port through the API server to ONE pod." \
  "Great for debugging – not a way to expose an application:" \
  "  - only works while the command runs" \
  "  - only on your machine" \
  "  - no load balancing"

# ── 4 · Service ────────────────────────────────────────────────────────────
section "4 · Create a Service"

show_file nginx-service.yml
pause

run "oc apply -f nginx-service.yml"
run "oc get service nginx"

comment "The service finds its pods via the label selector -> endpoints"
run "oc get endpointslices -l kubernetes.io/service-name=nginx"

#comment "Can we curl the service from here? The ClusterIP is internal only:"
#run "oc get service nginx -o jsonpath='{.spec.clusterIP}{\"\\n\"}'"

comment "So let's curl it from INSIDE the cluster"
show_file curl-pod.yml
run "oc create -f curl-pod.yml"
run "oc wait --for=condition=Ready pod/curl-pod --timeout=120s"
run "oc logs --tail=5 curl-pod"

discuss \
  "Services: a stable name for changing pods" \
  "" \
  "Pods come and go, their IPs change." \
  "A Service gets a stable ClusterIP and DNS name:" \
  "  nginx.<namespace>.svc.cluster.local" \
  "" \
  "It load-balances to all ready pods matching the selector." \
  "ClusterIP services are reachable only inside the cluster."

# ── 5 · Change the ConfigMap ───────────────────────────────────────────────
#section "5 · What happens if the ConfigMap changes?"

#show_file manifests/index-cm.yaml
#run "oc replace -f manifests/index-cm.yaml"

#comment "The curl pod keeps polling the service – wait for the new page"
#wait_until "'hello world 2' in the curl-pod log" 120 \
#  "oc logs --tail=3 curl-pod | grep -q 'hello world 2'" || true
#run "oc logs --tail=5 curl-pod"

# ── 6 · Route ──────────────────────────────────────────────────────────────
section "6 · Expose the service with a Route"

run "oc expose service nginx"
run "oc label route nginx ${DEMO_LABEL} --overwrite"

comment "What kind of resource was created?"
run "oc get route"

#comment "The declarative equivalent of 'oc expose'"
#show_file nginx-route.yml
pause

#ROUTE_HOST="$(oc get route nginx -o jsonpath='{.spec.host}' 2>/dev/null || true)"
#wait_until "router serves http://${ROUTE_HOST}" 60 "curl -fs http://${ROUTE_HOST}" || true
#run "curl -s http://\$(oc get route nginx -o jsonpath='{.spec.host}')"

# ── 7 · Edge route ─────────────────────────────────────────────────────────
section "7 · Expose the service via a TLS edge route"

run "oc create route edge nginx-ssl --service=nginx"
run "oc label route nginx-ssl ${DEMO_LABEL} --overwrite"

comment "Note the TERMINATION column"
run "oc get route"
#run "oc describe route nginx-ssl"

SSL_HOST="$(oc get route nginx-ssl -o jsonpath='{.spec.host}' 2>/dev/null || true)"
wait_until "router serves https://${SSL_HOST}" 60 "curl -kfs https://${SSL_HOST}" || true

comment "-k: the router uses the cluster's default (often self-signed) certificate"
run "curl -ks https://\$(oc get route nginx-ssl -o jsonpath='{.spec.host}')"

discuss \
  "Routes: getting traffic into the cluster" \
  "" \
  "The OpenShift router (HAProxy) forwards external HTTP(S)" \
  "traffic for a hostname to a Service." \
  "" \
  "TLS termination:" \
  "  edge        TLS ends at the router, plain HTTP to the pod" \
  "  passthrough TLS goes straight to the pod" \
  "  reencrypt   router terminates and re-encrypts to the pod"

takeaways \
  "oc port-forward is for debugging only" \
  "Services give pods a stable IP, DNS name and load balancing" \
  "Mounted ConfigMap changes reach running pods automatically" \
  "Routes expose services via the router: edge, passthrough, reencrypt" \
  "oc expose / oc create route are shortcuts for Route YAML"
