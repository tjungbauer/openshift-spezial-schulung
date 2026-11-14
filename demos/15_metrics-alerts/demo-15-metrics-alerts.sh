#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 15 – From metric to alert
#  Run:     ./demo-15-metrics-alerts.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in; user workload monitoring enabled on the cluster;
#           monitoring-edit (or admin) in the project for ServiceMonitor and
#           PrometheusRule. The queries run in the console: Observe › Metrics.
#  The demo runs in the project "demo-monitoring" (or NAME), created if missing.
#
#  The shop's catalog service, a steady load (~10 requests/s) and a curl Pod:
#    0  /metrics – the raw counters and histograms
#    1  ServiceMonitor – Prometheus scrapes the target
#    2  PromQL – rate and histogram_quantile
#    3  PrometheusRule – an injected error rate: pending, then firing
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-monitoring}"
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
# the label filter of every query: this project's catalog, without probes and scrapes
API="namespace=\"${DEMO_PROJECT}\",job=\"catalog\",endpoint!~\"/health/.*|/metrics\""

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

# fault JSON – switch faults in catalog (POST /admin/fault through the Service; 1 replica)
fault() {
  oc exec client -- curl -s -m 5 -X POST http://catalog:8080/admin/fault \
    -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' -d "$1"
  echo
}

# query TITLE PROMQL – show a query to paste into Observe › Metrics
query() {
  printf "\n%s   %s – Observe › Metrics › Custom query:%s\n" "${C_DIM}" "$1" "${C_RESET}"
  printf "%s   %s%s\n" "${C_CMD}" "$2" "${C_RESET}"
}

console_url() {
  printf "%s/monitoring/%s?namespace=%s" \
    "$(oc whoami --show-console 2>/dev/null)" "$1" "${DEMO_PROJECT}"
}

base_state() {   # for single steps
  oc apply -f catalog.yaml -f client.yaml -f load.yaml >/dev/null
  oc wait --for=condition=Ready pod/client --timeout=120s >/dev/null 2>&1 || true
  oc rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
  oc rollout status deployment/load --timeout=120s >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete -f prometheusrule.yaml -f servicemonitor.yaml -f load.yaml -f client.yaml -f catalog.yaml \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · /metrics – what the application exposes"

  run "oc apply -f catalog.yaml -f client.yaml -f load.yaml"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc rollout status deployment/load --timeout=120s"
  run "oc wait --for=condition=Ready pod/client --timeout=120s"
  comment "The load Pod calls catalog about 10 times a second"
  show_file load.yaml
  comment "The raw text format – a counter and a histogram"
  run "oc exec client -- curl -s http://catalog:8080/metrics | grep -E '^shop_http_requests_total' | head -8"
  run "oc exec client -- curl -s http://catalog:8080/metrics | grep -E '^shop_http_request_duration_seconds_bucket.*/products\"' | head -12"

  discuss \
    "Two metric types do most of the work" \
    "" \
    "  counter     shop_http_requests_total{method, endpoint, status}" \
    "              only goes up - you look at its rate" \
    "  histogram   shop_http_request_duration_seconds_bucket{le=...}" \
    "              how many requests were faster than le" \
    "" \
    "Labels keep it small: endpoint is the route (/products/{id}), not the URL."
}

step1() {
  section "1 · ServiceMonitor – tell Prometheus where to scrape"
  [[ "${MODE}" == "1" ]] && base_state

  show_file servicemonitor.yaml
  run "oc get service catalog --show-labels"
  run "oc apply -f servicemonitor.yaml"
  run "oc get servicemonitor"
  comment "Observe › Targets – the target appears within a minute:"
  run "echo $(console_url targets)"
  info "   waiting 60 s for the first scrapes ..."
  sleep 60
  pause

  discuss \
    "ServiceMonitor = label selector + port name + path" \
    "" \
    "Selects SERVICES by label - port by NAME (http), path /metrics." \
    "The user-workload Prometheus picks it up - no restart, no config file." \
    "" \
    "Target down? Wrong label, wrong port name - or a NetworkPolicy" \
    "that does not let the monitoring namespace in."
}

step2() {
  section "2 · PromQL – rate and histogram_quantile"
  [[ "${MODE}" == "2" ]] && base_state && oc apply -f servicemonitor.yaml >/dev/null

  comment "Open Observe › Metrics and paste the queries one by one:"
  run "echo $(console_url query-browser)"
  query "Requests per second, by status" \
    "sum by (status) (rate(shop_http_requests_total{${API}}[1m]))"
  query "Requests per second, by endpoint" \
    "sum by (endpoint) (rate(shop_http_requests_total{${API}}[1m]))"
  query "p95 latency in seconds" \
    "histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket{${API}}[2m])))"
  query "Error ratio (5xx share)" \
    "sum(rate(shop_http_requests_total{${API},status=~\"5..\"}[1m])) / sum(rate(shop_http_requests_total{${API}}[1m]))"
  pause

  discuss \
    "rate() for counters, histogram_quantile() for latency" \
    "" \
    "rate(x[1m])         per-second increase, averaged over 1 minute" \
    "sum by (status)     add up all Pods, keep one line per status" \
    "histogram_quantile  0.95 = 95 % of the requests were faster" \
    "" \
    "The 404 line is the load's 'does-not-exist' product - not an error" \
    "of catalog. That is why the alert looks at 5xx only."
}

step3() {
  section "3 · An alert – PrometheusRule, pending, firing"
  [[ "${MODE}" == "3" ]] && base_state && oc apply -f servicemonitor.yaml >/dev/null

  show_file prometheusrule.yaml
  run "oc apply -f prometheusrule.yaml"
  run "oc get prometheusrule"
  comment "30 % of the calls fail, every call 300 ms slower"
  run "fault '{\"error_rate\": 0.3, \"delay_ms\": 300}'"
  comment "Observe › Alerting – CatalogErrorRateHigh: pending after ~1 min, firing after ~2 min"
  run "echo $(console_url alerts)"
  info "   waiting 150 s – watch the alert change from pending to firing ..."
  sleep 150
  pause

  comment "Fault off – the alert resolves after the rate windows have passed"
  run "fault '{\"error_rate\": 0, \"delay_ms\": 0}'"

  discuss \
    "Alert = PromQL expression + for: + labels + annotations" \
    "" \
    "  pending   the expression is true - for: has not passed yet" \
    "  firing    true for longer than for: - goes to Alertmanager" \
    "" \
    "Alert on symptoms the user feels (errors, latency), not on CPU." \
    "Every alert needs a description - better: a runbook link."
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

    title "Demo 15 – From metric to alert" "/metrics · ServiceMonitor · PromQL · PrometheusRule"
    for i in 0 1 2 3; do "step${i}"; done

    takeaways \
      "Expose counters and histograms on /metrics – with few, bounded labels" \
      "A ServiceMonitor selects Services by label and the port by name" \
      "rate() for counters, histogram_quantile() for latency" \
      "Alert on what users feel – errors and latency – with for: against noise" \
      "Leave health checks and /metrics out of your queries"
    ;;
esac
