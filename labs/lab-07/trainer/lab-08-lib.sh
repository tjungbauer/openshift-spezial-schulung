# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 08 – shared tasks and checks.
#  Sourced by lab-08-walkthrough.sh (interactive) and lab-08-solve.sh
#  (automatic), all in lab-08/trainer/. The commands are the ones of the
#  student README; they run from lab-08/ with $NS, $SHOP_NS and $SHOP_WORK set.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created with an Argo CD
#              instance; the shop runs in LAB_NS-shop. Cleanup deletes both.)
#  Git:        GIT_REPO_URL       HTTPS URL of an EMPTY repository the trainer
#                                 owns – the scripts force-push to its branch main
#              GIT_USERNAME, GIT_TOKEN   credentials for push and for Argo CD
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-08-<namespace>)
#
#  The state of lab 7 (admin token, HPA) is created quietly if it is missing.
#  The alert state is read from the cluster's Thanos Querier (needs curl and a
#  cluster-admin login); without it the scripts wait a fixed time instead.
# ---------------------------------------------------------------------------

# this file lives in lab-08/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

OWN_PROJECTS=" lab "     # created by the lab -> cleanup deletes the projects
FAILS=0
SHOP_DEPLOY="${LAB_DIR}/../../shop/deploy"
APP_FILE="${LAB_DIR}/../day2-start/application-shop-dev.yaml"
SEL="app.kubernetes.io/name=catalog"
PREV_LAB_FILES="${LAB_DIR}/../lab-07/files"

# lab_init – call after parse_demo_args: tools, login, Git helper, variables
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd git sed
  require_oc_login
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-08-${LAB_NS}}"
  mkdir -p "${WORK_DIR}"

  # the variables of the student README
  export NS="${LAB_NS}"
  export SHOP_NS="${LAB_NS}-shop"
  export SHOP_WORK="${WORK_DIR}/shop-gitops"
  export SHOP_REPO="${GIT_REPO_URL:-}"
  export GIT_USER="${GIT_USERNAME:-}"
  export GIT_TOKEN="${GIT_TOKEN:-}"

  # push without a prompt: an askpass helper answers with the variables above
  cat > "${WORK_DIR}/askpass.sh" <<'EOS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "${GIT_USER}" ;;
  *)         printf '%s\n' "${GIT_TOKEN}" ;;
esac
EOS
  chmod 700 "${WORK_DIR}/askpass.sh"
  export GIT_ASKPASS="${WORK_DIR}/askpass.sh"
  export GIT_TERMINAL_PROMPT=0

  printf "%sShop:   %s %s\n" "${C_BOLD}" "${C_RESET}" "${SHOP_NS}"
  printf "%sRepo:   %s %s\n" "${C_BOLD}" "${C_RESET}" "${SHOP_REPO:-<not set>}"
  printf "%sFiles:  %s %s\n" "${C_BOLD}" "${C_RESET}" "${SHOP_WORK}"
  cd "${LAB_DIR}" || die "Cannot cd to ${LAB_DIR}"
}

need_repo() {
  [[ -n "${SHOP_REPO}" ]] || die "Set GIT_REPO_URL (HTTPS URL of an empty repository), GIT_USERNAME and GIT_TOKEN."
}

app_state() {
  oc -n "${NS}" get applications.argoproj.io shop-dev \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true
}

refresh() {
  oc -n "${NS}" annotate applications.argoproj.io shop-dev \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

wait_app() {     # wait_app [STATE] [TIMEOUT]
  local want="${1:-Synced/Healthy}"
  wait_until "shop-dev ${want}" "${2:-300}" "[[ \$(app_state) == '${want}' ]]" || true
}

wait_revision() {   # until Argo CD has synced HEAD of the work repo
  local head
  head="$(git -C "${SHOP_WORK}" rev-parse HEAD)"
  wait_until "shop-dev at ${head:0:7}" 180 \
    "{ refresh; [[ \$(oc -n '${NS}' get applications.argoproj.io shop-dev -o jsonpath='{.status.sync.revision}') == '${head}' ]]; }" || true
}

restarts() {
  oc -n "${SHOP_NS}" get pods -l "${SEL}" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}'
}

_commit_push() {   # _commit_push "message"
  git -C "${SHOP_WORK}" add .
  git -C "${SHOP_WORK}" commit -q -m "$1" || true
  git -C "${SHOP_WORK}" push -q --force -u origin main
}

# ensure_day2 – the state after labs/day2-start (the students do it by hand)
ensure_day2() {
  need_repo
  oc get crd argocds.argoproj.io >/dev/null 2>&1 \
    || die "No ArgoCD CRD – the OpenShift GitOps operator is not installed."
  oc -n "${NS}" get argocd argocd >/dev/null 2>&1 \
    || oc -n "${NS}" apply -f "${LAB_DIR}/../lab-05/trainer/argocd.yaml" >/dev/null
  wait_until "the Argo CD server in ${NS}" 300 \
    "oc -n '${NS}' rollout status deployment/argocd-server --timeout=5s" || true
  oc get namespace "${SHOP_NS}" >/dev/null 2>&1 || oc create namespace "${SHOP_NS}" >/dev/null
  oc label namespace "${SHOP_NS}" "argocd.argoproj.io/managed-by=${NS}" --overwrite >/dev/null
  if ! oc -n "${NS}" get secret shop-gitops-repo >/dev/null 2>&1; then
    oc -n "${NS}" create secret generic shop-gitops-repo \
      --from-literal=type=git --from-literal=url="${SHOP_REPO}" \
      --from-literal=username="${GIT_USER}" --from-literal=password="${GIT_TOKEN}" >/dev/null
    oc -n "${NS}" label secret shop-gitops-repo argocd.argoproj.io/secret-type=repository >/dev/null
  fi
  if [[ ! -d "${SHOP_WORK}/.git" ]]; then
    rm -rf "${SHOP_WORK}"
    mkdir -p "${SHOP_WORK}"
    cp -r "${SHOP_DEPLOY}/base" "${SHOP_DEPLOY}/components" "${SHOP_DEPLOY}/overlays" "${SHOP_WORK}/"
    git -C "${SHOP_WORK}" init -q -b main
    git -C "${SHOP_WORK}" config user.name "${NS}"
    git -C "${SHOP_WORK}" config user.email "${NS}@training.example"
    git -C "${SHOP_WORK}" remote add origin "${SHOP_REPO}"
    _commit_push "shop: base, components, overlays"
  fi
  sed -e "s|<NS>|${NS}|g" -e "s|<REPO_URL>|${SHOP_REPO}|" "${APP_FILE}" | oc -n "${NS}" apply -f - >/dev/null
  oc project "${SHOP_NS}" >/dev/null
  wait_revision
  wait_app
}

# _ensure STEP – a single task needs the state of the tasks before it
_ensure() {
  ensure_day2
  if [[ ! -f "${SHOP_WORK}/overlays/dev/hpa-catalog.yaml" ]]; then
    # the end of lab 7: admin token, HPA, no replica count in Git
    cp "${PREV_LAB_FILES}/patch-catalog-lab.yaml" "${PREV_LAB_FILES}/hpa-catalog.yaml" "${SHOP_WORK}/overlays/dev/"
    cp "${PREV_LAB_FILES}/kustomization-dev-hpa.yaml" "${SHOP_WORK}/overlays/dev/kustomization.yaml"
    _commit_push "dev: admin token and HPA for catalog (lab 7)"
    wait_revision
    oc -n "${SHOP_NS}" rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
  fi
  if [[ $1 -ge 2 ]] && ! oc -n "${SHOP_NS}" get deployment traffic >/dev/null 2>&1; then
    oc -n "${SHOP_NS}" apply -f files/traffic.yaml >/dev/null
    oc -n "${SHOP_NS}" rollout status deployment/traffic --timeout=120s >/dev/null 2>&1 || true
  fi
  if [[ $1 -ge 5 ]] && [[ ! -f "${SHOP_WORK}/overlays/dev/prometheusrule-catalog.yaml" ]]; then
    cp files/prometheusrule-catalog.yaml "${SHOP_WORK}/overlays/dev/"
    cp files/kustomization-dev-alert.yaml "${SHOP_WORK}/overlays/dev/kustomization.yaml"
    _commit_push "dev: alerts for catalog"
    wait_revision
  fi
  if [[ $1 -ge 6 ]] && [[ $(failed_lines) -eq 0 ]]; then
    # task 6 needs 503 lines: a short burst of errors
    ./files/fault.sh '{"error_rate": 0.3}' >/dev/null
    sleep 20
    ./files/fault.sh '{"error_rate": 0}' >/dev/null
  fi
  return 0
}

# the step after every push in the README
REFRESH_CMD="oc -n \$NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite"
# the label filter of the README queries
API='job="catalog",endpoint!~"/health/.*|/metrics"'

failed_lines() {
  oc -n "${SHOP_NS}" logs -l "${SEL}" --tail=-1 --since=10m 2>/dev/null | grep -c '"status": 503' || true
}

console_url() {   # console_url PAGE
  printf "%s/monitoring/%s?namespace=%s" "$(oc whoami --show-console 2>/dev/null)" "$1" "${SHOP_NS}"
}

# ── the cluster's Thanos Querier (trainer only: needs cluster-admin and curl) ──
_thanos() {   # _thanos PATH [curl args] – prints JSON, fails without access
  local host
  command -v curl >/dev/null 2>&1 || return 1
  host="$(oc -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}' 2>/dev/null)" || return 1
  [[ -n "${host}" ]] || return 1
  curl -skf -m 10 -H "Authorization: Bearer $(oc whoami -t)" "https://${host}$1" "${@:2}"
}

# prom PROMQL – the README query, run for this namespace; prints "labels = value" lines
prom() {
  local q json
  # the console adds the namespace for the students – here it must be explicit
  q="${1//job=\"catalog\"/namespace=\"${SHOP_NS}\",job=\"catalog\"}"
  [[ "${q}" == "up" ]] && q="up{namespace=\"${SHOP_NS}\"}"
  json="$(_thanos /api/v1/query -G --data-urlencode "query=${q}")" || { info "   (no access to the Thanos Querier – look at the console)"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${json}" | python3 -c '
import json, sys
res = json.load(sys.stdin)["data"]["result"]
if not res:
    print("   (no data)")
for r in res:
    m = {k: v for k, v in r["metric"].items() if k in ("job", "pod", "status", "endpoint", "le")}
    print("   %-60s %s" % (", ".join("%s=%s" % kv for kv in sorted(m.items())) or "{}", r["value"][1]))'
  else
    printf '   %s\n' "${json}"
  fi
}

# alert_state NAME – inactive, pending or firing (empty without access)
alert_state() {
  local json
  json="$(_thanos /api/v1/alerts)" || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  printf '%s' "${json}" | python3 -c '
import json, sys
name, ns = sys.argv[1], sys.argv[2]
states = [a["state"] for a in json.load(sys.stdin)["data"]["alerts"]
          if a["labels"].get("alertname") == name and a["labels"].get("namespace") == ns]
print("firing" if "firing" in states else "pending" if states else "inactive")' "$1" "${SHOP_NS}"
}

# wait_alert NAME STATE TIMEOUT – poll the alert, or just wait without access
wait_alert() {
  if [[ -n "$(alert_state "$1")" ]]; then
    wait_until "$1 ${2}" "$3" "[[ \$(alert_state '$1') == '$2' ]]" || true
  else
    info "   (alert state not readable – waiting $3 s, watch Observe › Alerting)"
    sleep "$3"
  fi
}

query() {   # query TITLE PROMQL – show a README query, and its result for the trainer
  printf "\n%s   %s – Observe › Metrics:%s\n" "${C_DIM}" "$1" "${C_RESET}"
  printf "%s   %s%s\n" "${C_CMD}" "$2" "${C_RESET}"
  prom "$2"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · The ServiceMonitors"
  _ensure 1

  run "oc get servicemonitor"
  run "oc get servicemonitor catalog -o yaml | grep -A4 -E '^  (selector|endpoints):'"
  run "oc get service catalog -o jsonpath='{.metadata.labels.app\\.kubernetes\\.io/name}  {.spec.ports[*].name}{\"\\n\"}'"
  run "cat \"\$SHOP_WORK/components/monitoring/kustomization.yaml\""
  show_file files/traffic.yaml
  run "oc apply -f files/traffic.yaml"
  run "oc rollout status deployment/traffic --timeout=120s"

  discuss \
    "ServiceMonitor = Service label + port name + path" \
    "" \
    "Four, from the component 'monitoring' - in Git since Day 2 start." \
    "No Pod names, no port numbers: each Pod behind it is a target." \
    "web has none - nginx exposes no metrics."
}

task2() {
  section "Task 2 · Is it scraped?"
  _ensure 2

  comment "Observe › Metrics, shop namespace selected:"
  run "echo $(console_url query-browser)"
  query "Every target, 1 = scraped" "up"
  query "What one target delivers" "shop_http_requests_total{job=\"catalog\"}"
  pause

  discuss \
    "Run 'up' first - before you trust any graph" \
    "" \
    "missing    the ServiceMonitor selects nothing (label, port name)" \
    "0          found, but not scraped (NetworkPolicy, path)" \
    "1          fine - catalog twice: two replicas, two targets"
}

task3() {
  section "Task 3 · Query it"
  _ensure 3

  query "Requests per second, by status" \
    "sum by (status) (rate(shop_http_requests_total{${API}}[1m]))"
  query "Requests per second, by endpoint" \
    "sum by (endpoint) (rate(shop_http_requests_total{${API}}[1m]))"
  query "p95 latency in seconds" \
    "histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket{${API}}[2m])))"
  query "Error ratio (no data yet - no 5xx)" \
    "sum(rate(shop_http_requests_total{job=\"catalog\",status=~\"5..\",endpoint!~\"/health/.*|/metrics\"}[1m])) / sum(rate(shop_http_requests_total{${API}}[1m]))"
  pause

  discuss \
    "rate() for counters, histogram_quantile() for latency" \
    "" \
    "rate(x[1m])        per second, averaged over one minute" \
    "sum by (status)    both Pods added up, one line per status" \
    "endpoint!~...      without probes and scrapes - they never fail"
}

task4() {
  section "Task 4 · An alert"
  _ensure 4

  show_file files/prometheusrule-catalog.yaml
  run "diff \"\$SHOP_WORK/overlays/dev/kustomization.yaml\" files/kustomization-dev-alert.yaml || true"
  run "cp files/prometheusrule-catalog.yaml \"\$SHOP_WORK/overlays/dev/\""
  run "cp files/kustomization-dev-alert.yaml \"\$SHOP_WORK/overlays/dev/kustomization.yaml\""
  run "oc kustomize \"\$SHOP_WORK/overlays/dev\" | grep -A3 '^kind: PrometheusRule'"
  run "git -C \"\$SHOP_WORK\" add ."
  run "git -C \"\$SHOP_WORK\" commit -m 'dev: alerts for catalog' || true"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
  wait_until "the PrometheusRule catalog" 60 "oc get prometheusrule catalog >/dev/null 2>&1" || true
  run "oc get prometheusrule"
  comment "Observe › Alerting › Alerting rules:"
  run "echo $(console_url alerts)"

  discuss \
    "Alert = your query + a threshold + for:" \
    "" \
    "error ratio > 0.05 for 1 minute - no namespace in the rule:" \
    "user workload monitoring adds it, a rule sees only its namespace." \
    "In Git like everything else - reviewed, versioned, promoted."
}

task5() {
  section "Task 5 · Make it fire"
  _ensure 5

  show_file files/fault.sh
  run "./files/fault.sh '{\"error_rate\": 0.3}'"
  comment "Observe › Alerting – pending after ~1 min, firing ~1 min later"
  wait_alert CatalogErrorRateHigh firing 180
  query "Requests per second, by status" \
    "sum by (status) (rate(shop_http_requests_total{${API}}[1m]))"
  pause

  run "./files/fault.sh '{\"error_rate\": 0}'"

  discuss \
    "inactive -> pending -> firing" \
    "" \
    "pending   expression true, for: not over yet" \
    "firing    goes to the Alertmanager" \
    "" \
    "Alert on symptoms (failed calls), find the cause in the logs."
}

task6() {
  section "Task 6 · Find the logs"
  _ensure 6

  run "oc logs -l ${SEL} --tail=-1 --since=10m --prefix | grep '\"status\": 503' | tail -3"
  run "ID=\$(oc logs -l ${SEL} --tail=-1 --since=10m | grep '\"status\": 503' | tail -1 | sed -E 's/.*\"request_id\": \"([^\"]+)\".*/\\1/'); echo \$ID"
  ID="$(oc -n "${SHOP_NS}" logs -l "${SEL}" --tail=-1 --since=10m | grep '"status": 503' | tail -1 | sed -E 's/.*"request_id": "([^"]+)".*/\1/')"
  export ID
  run "oc logs -l ${SEL} --tail=-1 --since=10m --prefix | grep \"\$ID\""
  run "oc logs deployment/web --since=10m | grep \"\$ID\""
  run "oc logs -l ${SEL} --tail=-1 --since=10m | grep '\"message\": \"faults changed\"'"

  discuss \
    "One request id - every service it touched" \
    "" \
    "web creates it (or keeps X-Request-ID) and passes it on." \
    "503 is logged at level info - filter on status, not on level." \
    "oc logs knows only running Pods - Observe > Logs (LokiStack) keeps them."
}

bonus() {
  section "Bonus · The slow alert"
  _ensure 5
  run "./files/fault.sh '{\"delay_ms\": 800}'"
  wait_alert CatalogSlow firing 240
  query "p95 latency in seconds" \
    "histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket{${API}}[2m])))"
  run "./files/fault.sh '{\"delay_ms\": 0}'"
}

# the README's cleanup: faults off, traffic gone – the alerts stay in Git
stop_traffic() {
  section "Cleanup · stop the traffic"
  run "./files/fault.sh '{\"error_rate\": 0, \"delay_ms\": 0}'"
  run "oc delete -f files/traffic.yaml"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Checks
# ═══════════════════════════════════════════════════════════════════════════

expect() {
  if [[ "$2" == "$3" ]]; then
    printf "  %sPASS%s  %-44s %s\n" "${C_OK}" "${C_RESET}" "$1" "$3"
  else
    printf "  %sFAIL%s  %-44s got %s, expected %s\n" "${C_ERR}" "${C_RESET}" "$1" "${3:-nothing}" "$2"
    FAILS=$((FAILS + 1))
  fi
}

_jp() { oc -n "${SHOP_NS}" get "$1" -o jsonpath="$2" 2>/dev/null || true; }

check() {
  FAILS=0
  section "Checks for ${NS} / ${SHOP_NS}"
  expect "shop-dev Synced/Healthy" "Synced/Healthy" "$(app_state)"
  expect "four ServiceMonitors (task 1)" "4" \
    "$(oc -n "${SHOP_NS}" get servicemonitor --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  expect "PrometheusRule catalog (task 4)" "CatalogErrorRateHigh" \
    "$(_jp prometheusrule/catalog '{.spec.groups[0].rules[0].alert}')"
  # Argo CD marks what it manages: annotation (default) or label, depending on its setting
  expect "the rule comes from Argo CD" "shop-dev" \
    "$( { _jp prometheusrule/catalog '{.metadata.annotations.argocd\.argoproj\.io/tracking-id}'
          _jp prometheusrule/catalog '{.metadata.labels.app\.kubernetes\.io/instance}'; } | cut -d: -f1 | grep -m1 . || true)"
  expect "HPA catalog still in place (lab 7)" "2" "$(_jp hpa/catalog '{.spec.minReplicas}')"
  local state
  state="$(alert_state CatalogErrorRateHigh)"
  if [[ -n "${state}" ]]; then
    expect "CatalogErrorRateHigh resolved (fault off)" "inactive" "${state}"
  else
    info "  ----  CatalogErrorRateHigh state                 not readable (needs cluster-admin + curl)"
  fi
  expect "traffic generator removed (cleanup)" "no" \
    "$(oc -n "${SHOP_NS}" get deployment traffic >/dev/null 2>&1 && echo yes || echo no)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  oc -n "${SHOP_NS}" delete -f "${LAB_DIR}/files/traffic.yaml" --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${OWN_PROJECTS}" == *" ${LAB_NS} "* ]]; then
    oc -n "${NS}" delete applications.argoproj.io shop-dev --ignore-not-found >/dev/null 2>&1 || true
    oc delete project "${SHOP_NS}" "${NS}" --ignore-not-found >/dev/null 2>&1 || true
    info "deleted the projects ${NS} and ${SHOP_NS}"
  else
    # a student's namespace: lab 9 continues with this state – only the lab tool goes
    info "removed the traffic generator in ${SHOP_NS} (the shop, its alerts and the Application stay)"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
