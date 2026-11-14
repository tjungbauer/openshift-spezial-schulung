# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 03 – shared tasks and checks.
#  Sourced by lab-03-walkthrough.sh (interactive) and lab-03-solve.sh
#  (automatic), all three in lab-03/trainer/. The chart is built step by step
#  in a work folder from the files in lab-03/reference/ – exactly the files
#  the students write in the README.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created, deleted by cleanup)
#  Release:    website
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-03-<namespace>)
# ---------------------------------------------------------------------------

# this file lives in lab-03/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

RELEASE="website"
OWN_PROJECTS=" lab "     # created by the lab -> cleanup deletes the project
FAILS=0
export REF="${LAB_DIR}/reference/website"   # shown as $REF in the commands
export BONUS="${LAB_DIR}/reference/bonus"

# lab_init – call after parse_demo_args: tools, login, work folder
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd helm curl
  require_oc_login
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-03-${LAB_NS}}"
  mkdir -p "${WORK_DIR}"
  printf "%sChart:  %s %s/website\n" "${C_BOLD}" "${C_RESET}" "${WORK_DIR}"
  cd "${WORK_DIR}" || die "Cannot cd to ${WORK_DIR}"
}

route_url() {
  printf "https://%s" "$(oc -n "${LAB_NS}" get route "${RELEASE}" -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# route_code – HTTP code of the Route from this machine, "none" or "blocked"
route_code() {
  local c
  oc -n "${LAB_NS}" get route "${RELEASE}" >/dev/null 2>&1 || { printf "none"; return 0; }
  c=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$(route_url)" 2>/dev/null || true)
  [[ "${c}" =~ ^[1-5][0-9][0-9]$ ]] && printf "%s" "${c}" || printf "blocked"
}

# _ensure STEP – a single task needs the result of the tasks before it:
# build the missing parts quietly from the reference files
_ensure() {
  local step="$1"
  if [[ ${step} -ge 2 && ! -f website/templates/_helpers.tpl ]]; then
    rm -rf website
    helm create website >/dev/null
    find website/templates -mindepth 1 ! -name _helpers.tpl -delete
  fi
  [[ ${step} -ge 3 ]] && cp "${REF}/Chart.yaml" "${REF}/values.yaml" website/
  [[ ${step} -ge 4 ]] && cp "${REF}/templates/deployment.yaml" website/templates/
  [[ ${step} -ge 5 ]] && cp "${REF}/templates/service.yaml" "${REF}/templates/route.yaml" \
                            "${REF}/templates/NOTES.txt" website/templates/
  if [[ ${step} -ge 6 ]] && ! helm status "${RELEASE}" >/dev/null 2>&1; then
    helm install "${RELEASE}" ./website --wait --timeout 3m >/dev/null
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Scaffold a chart"
  rm -rf website

  run "helm create website"
  run "find website -type f | sort"

  comment "Keep only the helpers – we write the rest ourselves"
  run "find website/templates -mindepth 1 ! -name _helpers.tpl -delete"
  run "find website -type f | sort"
  show_file website/templates/_helpers.tpl
  pause

  discuss \
    "helm create = a working example chart to start from" \
    "" \
    "  Chart.yaml        name and versions" \
    "  values.yaml       defaults" \
    "  templates/        rendered into Kubernetes objects" \
    "  _helpers.tpl      named templates - never an object itself" \
    "" \
    "website.fullname, website.labels, website.selectorLabels:" \
    "we call them with  include \"website.labels\" ."
}

task2() {
  section "Task 2 · Chart.yaml and values.yaml"
  _ensure 2

  run "cp \$REF/Chart.yaml \$REF/values.yaml website/"
  show_file website/Chart.yaml
  show_file website/values.yaml
  pause

  discuss \
    "version = the chart   appVersion = the application" \
    "" \
    "appVersion 1.29.1 is the nginx version - and our default image tag." \
    "" \
    "values.yaml offers only the knobs we want to change:" \
    "  replicaCount, image.repository, image.tag, route.enabled, route.host" \
    "Everything else stays fixed in the templates."
}

task3() {
  section "Task 3 · The Deployment template"
  _ensure 3

  run "cp \$REF/templates/deployment.yaml website/templates/"
  show_file website/templates/deployment.yaml
  pause

  comment "Render only this file – no cluster needed"
  run "helm template website ./website --show-only templates/deployment.yaml"

  discuss \
    "Where do the values come from?" \
    "" \
    "  .Values.replicaCount      values.yaml" \
    "  .Chart.AppVersion         Chart.yaml (image tag if image.tag is empty)" \
    "  include \"website...\" .    the helpers" \
    "" \
    "{{-  trims whitespace,  nindent 4  = newline + 4 spaces." \
    "The selector uses only the selector labels - the version may change," \
    "the selector of a Deployment may not."
}

task4() {
  section "Task 4 · Service, Route and NOTES"
  _ensure 4

  run "cp \$REF/templates/service.yaml \$REF/templates/route.yaml \$REF/templates/NOTES.txt website/templates/"
  show_file website/templates/route.yaml
  show_file website/templates/NOTES.txt
  pause

  comment "route.enabled=false – the Route disappears"
  run "helm template website ./website --set route.enabled=false | grep kind:"

  discuss \
    "if, with and NOTES.txt" \
    "" \
    "  if .Values.route.enabled    the whole Route on or off" \
    "  with .Values.route.host     host only when a value is given;" \
    "                              inside with, the dot IS the host" \
    "  NOTES.txt                   printed after install and upgrade"
}

task5() {
  section "Task 5 · Render, lint, install"
  _ensure 5
  helm uninstall "${RELEASE}" --wait >/dev/null 2>&1 || true

  run "helm lint website"
  run "helm template website ./website"
  run "helm install website ./website"
  run "helm list"
  run "oc get deployment,service,route -l app.kubernetes.io/instance=website"
  run "oc rollout status deployment/website --timeout=120s"

  wait_until "the router serves the Route" 60 "[[ \$(route_code) == 200 ]]" || true
  run "curl -k -s https://\$(oc get route website -o jsonpath='{.spec.host}') | head -5"

  discuss \
    "helm template = local   helm install = a release in the cluster" \
    "" \
    "Release website, revision 1 - the state is a Secret in the namespace:" \
    "  oc get secret -l owner=helm" \
    "" \
    "The objects are called 'website': the release name contains" \
    "the chart name, so website.fullname does not add it twice."
}

task6() {
  section "Task 6 · Upgrade and roll back"
  _ensure 6

  run "helm upgrade website ./website --set replicaCount=3"
  run "oc rollout status deployment/website --timeout=120s"
  run "oc get pods -l app.kubernetes.io/instance=website"
  run "helm get values website"
  run "helm history website"

  run "helm rollback website 1"
  run "helm history website"
  wait_until "back to one pod" 90 \
    "[[ \$(oc get deployment website -o jsonpath='{.status.replicas}') == 1 ]]" || true
  run "oc get pods -l app.kubernetes.io/instance=website"

  discuss \
    "Every install, upgrade and rollback = a new revision" \
    "" \
    "  revision 1  install" \
    "  revision 2  upgrade --set replicaCount=3" \
    "  revision 3  rollback to 1 - one replica again" \
    "" \
    "helm get values shows what was passed with --set." \
    "Without --set, the next upgrade uses the chart defaults again."
}

bonus() {
  section "Bonus · your own page – ConfigMap and checksum"
  _ensure 6

  run "cp \$BONUS/configmap.yaml \$BONUS/deployment.yaml website/templates/"
  show_file website/templates/configmap.yaml
  run "grep -n -A1 annotations website/templates/deployment.yaml"
  pause

  run "helm upgrade website ./website --set message='Hello from ${LAB_NS}'"
  run "oc rollout status deployment/website --timeout=120s"
  wait_until "the new page" 60 "[[ \$(curl -ks \$(route_url)) == *'Hello from'* ]]" || true
  run "curl -k -s https://\$(oc get route website -o jsonpath='{.spec.host}')"

  comment "The same message again: same checksum – no new Pods"
  run "helm upgrade website ./website --set message='Hello from ${LAB_NS}'"
  run "oc get pods -l app.kubernetes.io/instance=website"

  run "helm package website"
  run "helm show chart website-0.1.0.tgz"

  discuss \
    "checksum/page = sha256 of the rendered ConfigMap" \
    "" \
    "New page -> new checksum -> new Pod template -> rolling update." \
    "Same page -> same Pod template -> nothing happens." \
    "" \
    "helm package: the chart as a .tgz - ready for a chart repository" \
    "or an OCI registry (helm push)."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Checks
# ═══════════════════════════════════════════════════════════════════════════

# expect DESCRIPTION EXPECTED ACTUAL – one PASS/FAIL line
expect() {
  if [[ "$2" == "$3" ]]; then
    printf "  %sPASS%s  %-44s %s\n" "${C_OK}" "${C_RESET}" "$1" "$3"
  else
    printf "  %sFAIL%s  %-44s got %s, expected %s\n" "${C_ERR}" "${C_RESET}" "$1" "${3:-nothing}" "$2"
    FAILS=$((FAILS + 1))
  fi
}

check() {
  local ready revs
  FAILS=0
  section "Checks for release ${RELEASE} in ${LAB_NS}"
  ready="$(oc -n "${LAB_NS}" get deployment "${RELEASE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  revs="$(helm -n "${LAB_NS}" history "${RELEASE}" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"

  expect "Release website is deployed" "yes" \
    "$(helm -n "${LAB_NS}" list -q --deployed 2>/dev/null | grep -qx "${RELEASE}" && echo yes || echo no)"
  expect "Deployment managed by Helm" "Helm" \
    "$(oc -n "${LAB_NS}" get deployment "${RELEASE}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  expect "Deployment ready" "yes" "$([[ "${ready:-0}" -ge 1 ]] && echo yes || echo no)"
  expect "Image from appVersion" "quay.io/nginx/nginx-unprivileged:1.29.1" \
    "$(oc -n "${LAB_NS}" get deployment "${RELEASE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  expect "Service website → port 8080" "8080" \
    "$(oc -n "${LAB_NS}" get service "${RELEASE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  expect "Route is edge-terminated" "edge" \
    "$(oc -n "${LAB_NS}" get route "${RELEASE}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)"
  expect "Route answers" "200" "$(route_code)"
  expect "Upgrade and rollback done (≥ 3 revisions)" "yes" "$([[ "${revs:-0}" -ge 3 ]] && echo yes || echo no)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  helm -n "${LAB_NS}" uninstall "${RELEASE}" >/dev/null 2>&1 || true
  info "uninstalled release ${RELEASE} in ${LAB_NS}"
  if [[ "${OWN_PROJECTS}" == *" ${LAB_NS} "* ]]; then
    oc delete project "${LAB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    info "deleted project ${LAB_NS}"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
