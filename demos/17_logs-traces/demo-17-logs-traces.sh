#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 17 – One request, three signals
#  Run:     ./demo-17-logs-traces.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; the cluster pulls the shop images from quay.io and
#           quay.io/jaegertracing/jaeger (step 2). No logging or tracing stack
#           needed: the logs come from oc logs, the traces go to a Jaeger Pod.
#  The demo runs in the project "demo-traces" (or NAME), created if missing.
#
#  The shop (web, catalog, cart, orders, review) and a curl Pod:
#    0  one JSON log line per request – the request id in the answer
#    1  one order, three services – the same request id in web, orders, catalog
#    2  tracing on – one environment variable, the trace in Jaeger
#    3  a delay in catalog – where did the time go?
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-traces}"
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

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

# the order the client places – through web, as the browser would
ORDER='{"items": [{"product_id": "mug", "quantity": 1}]}'

# order ID – the command that places one order with our own request id
order() {
  printf "oc exec client -- curl -s -m 20 -X POST http://web:8080/api/orders/orders -H 'X-Request-ID: %s' -H 'Content-Type: application/json' -d '%s'; echo" "$1" "${ORDER}"
}

# trail ID – the command that shows the log lines of one request in web, orders and catalog
trail() {
  # shellcheck disable=SC2016  # $d is for the shell that runs the command
  printf 'for d in web orders catalog; do oc logs deployment/$d --since=10m | grep -F %s; done' "$1"
}

# trace_of ID – the trace id that orders logged for this request
trace_of() {
  oc logs deployment/orders --since=10m | grep -F "$1" | grep -o '"trace_id": "[0-9a-f]*"' \
    | head -1 | cut -d'"' -f4 || true
}

# fault JSON – switch faults in catalog (POST /admin/fault through the Service; 1 replica)
fault() {
  oc exec client -- curl -s -m 5 -X POST http://catalog:8080/admin/fault \
    -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' -d "$1"
  echo
}

# jaeger_url [TRACE] – the trace in the Jaeger UI, or the search for service orders
jaeger_url() {
  local host
  host="$(oc get route jaeger -o jsonpath='{.spec.host}' 2>/dev/null)"
  if [[ -n "${1:-}" ]]; then
    printf "https://%s/trace/%s" "${host}" "$1"
  else
    printf "https://%s/search?service=orders" "${host}"
  fi
}

new_id() { printf "demo17-%s-%s" "$1" "$(date +%H%M%S)"; }

base_state() {   # for single steps
  oc apply -k . >/dev/null
  oc wait --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1 || true
  for d in web catalog orders cart; do
    oc rollout status "deployment/${d}" --timeout=180s >/dev/null 2>&1 || true
  done
}

tracing_state() {   # step 3 alone needs Jaeger and tracing on
  oc apply -f jaeger.yaml >/dev/null
  oc set env deployment/orders deployment/catalog OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318 >/dev/null
  for d in jaeger orders catalog; do
    oc rollout status "deployment/${d}" --timeout=180s >/dev/null 2>&1 || true
  done
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f jaeger.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete -k . --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · One JSON log line per request"

  run "oc apply -k ."
  run "oc rollout status deployment/web --timeout=180s"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc rollout status deployment/orders --timeout=180s"
  run "oc wait --for=condition=Ready pod/client --timeout=120s"
  comment "One call through web – the answer carries the request id (web's and catalog's header)"
  run "oc exec client -- curl -s -o /dev/null -D - http://web:8080/api/catalog/products | grep -i -E '^(HTTP|x-request-id|x-shop-app)'"
  comment "The log line of that call in catalog – one JSON object"
  run "oc logs deployment/catalog --tail=1"

  discuss \
    "Logs for machines: one line, one event, JSON" \
    "" \
    "time, level, service, pod, message, request_id," \
    "method, path, status, duration_ms" \
    "" \
    "To stdout - OpenShift collects it. No log files, no agent." \
    "Every field can be filtered - by a log store, or by grep."
}

step1() {
  section "1 · One order, three services – one request id"
  [[ "${MODE}" == "1" ]] && base_state

  ID="$(new_id order)"
  comment "We set the request id ourselves: X-Request-ID: ${ID}"
  run "$(order "${ID}")"
  comment "web → orders → catalog (stock reservation): the same id everywhere"
  run "$(trail "${ID}")"

  discuss \
    "The request id is passed on - by every service" \
    "" \
    "web keeps the caller's X-Request-ID (or creates one), sends it on;" \
    "orders sends it on to catalog. One grep - the whole request." \
    "" \
    "But: which call was slow? Three durations, three clocks, no order."
}

step2() {
  section "2 · Tracing on – one environment variable"
  [[ "${MODE}" == "2" ]] && base_state

  comment "Jaeger as a stand-in for Tempo – OTLP in on 4318, UI on 16686"
  #show_file jaeger.yaml
  run "oc apply -f jaeger.yaml"
  run "oc rollout status deployment/jaeger --timeout=180s"
  comment "The shop has OpenTelemetry built in – off until it knows where to send spans"
  run "oc set env deployment/orders deployment/catalog OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318"
  run "oc rollout status deployment/orders --timeout=180s"
  run "oc rollout status deployment/catalog --timeout=180s"

  ID="$(new_id traced)"
  run "$(order "${ID}")"
  comment "The log lines now carry a trace_id – logs and traces are linked"
  run "$(trail "${ID}")"
  TRACE="$(trace_of "${ID}")"
  info "   waiting 10 s – the spans are sent in batches ..."
  sleep 10
  comment "Open the trace in Jaeger (service orders):"
  run "echo $(jaeger_url "${TRACE}")"
  pause

  discuss \
    "A trace = one request, all its spans, one clock" \
    "" \
    "orders    POST /orders           the root span" \
    "  orders    POST                 the call to catalog (httpx)" \
    "  catalog   POST /stock/reserve  the server side" \
    "(the 'http receive / send' spans are framework details)" \
    "" \
    "traceparent header carries the trace id from service to service." \
    "On OpenShift: Tempo + OpenTelemetry collector, Observe > Traces."
}

step3() {
  section "3 · A delay in catalog – where did the time go?"
  [[ "${MODE}" == "3" ]] && base_state && tracing_state

  comment "Every catalog call 800 ms slower"
  run "fault '{\"delay_ms\": 800}'"
  ID="$(new_id slow)"
  run "$(order "${ID}")"
  run "$(trail "${ID}")"
  TRACE="$(trace_of "${ID}")"
  sleep 10
  comment "The trace – catalog's span takes the 800 ms, orders only waits:"
  run "echo $(jaeger_url "${TRACE}")"
  pause

  comment "Fault off"
  run "fault '{\"delay_ms\": 0}'"

  discuss \
    "Metrics say THAT it is slow, the trace says WHERE" \
    "" \
    "web and orders log ~800 ms too - they only waited." \
    "In the trace, the catalog span covers the 800 ms." \
    "The span tree shows the hop that spent the time." \
    "" \
    "Start with metrics, drill into logs, follow a trace."
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
    oc wait --for=delete pod -l app.kubernetes.io/part-of=demo-17 --timeout=60s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects? [y/N]"

    title "Demo 17 – One request, three signals" "JSON logs · request id · traces"
    for i in 0 1 2 3; do "step${i}"; done

    takeaways \
      "Log one JSON line per request to stdout – OpenShift collects it" \
      "Pass a request id on – one search finds a request in every service" \
      "Tracing is one environment variable when the app is instrumented" \
      "A trace shows where the time went – not just that it was slow" \
      "Metrics: is there a problem? Logs: what? Traces: where?"
    ;;
esac
