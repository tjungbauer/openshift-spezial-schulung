# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 07 – shared tasks and checks.
#  Sourced by lab-07-walkthrough.sh (interactive) and lab-07-solve.sh
#  (automatic), all in lab-07/trainer/. The commands are the ones of the
#  student README; they run from lab-07/ with $NS, $SHOP_NS and $SHOP_WORK set.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created with an Argo CD
#              instance; the shop runs in LAB_NS-shop. Cleanup deletes both.)
#  Git:        GIT_REPO_URL       HTTPS URL of an EMPTY repository the trainer
#                                 owns – the scripts force-push to its branch main
#              GIT_USERNAME, GIT_TOKEN   credentials for push and for Argo CD
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-07-<namespace>)
# ---------------------------------------------------------------------------

# this file lives in lab-07/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

OWN_PROJECTS=" lab "     # created by the lab -> cleanup deletes the projects
FAILS=0
SHOP_DEPLOY="${LAB_DIR}/../../shop/deploy"
APP_FILE="${LAB_DIR}/../day2-start/application-shop-dev.yaml"
SEL="app.kubernetes.io/name=catalog"

# lab_init – call after parse_demo_args: tools, login, Git helper, variables
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd git sed
  require_oc_login
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-07-${LAB_NS}}"
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
  # only if missing – applying it again would switch auto-sync back on
  oc -n "${NS}" get applications.argoproj.io shop-dev >/dev/null 2>&1 \
    || sed -e "s|<NS>|${NS}|g" -e "s|<REPO_URL>|${SHOP_REPO}|" "${APP_FILE}" | oc -n "${NS}" apply -f - >/dev/null
  oc project "${SHOP_NS}" >/dev/null
  if autosync_on; then
    wait_revision
    wait_app
  fi
}

autosync_on() {
  [[ -n "$(oc -n "${NS}" get applications.argoproj.io shop-dev -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)" ]]
}

autosync_off() {   # quietly – used by _ensure
  autosync_on || return 0
  oc -n "${NS}" patch applications.argoproj.io shop-dev --type=json \
    -p '[{"op": "remove", "path": "/spec/syncPolicy/automated"}]' >/dev/null
}

catalog_env() {   # catalog_env NAME – value of an env variable in the live Deployment
  oc -n "${SHOP_NS}" get deployment catalog \
    -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}" 2>/dev/null || true
}

# _ensure STEP – a single task needs the state of the tasks before it
#   task 2-5: auto-sync off; from task 4 on: the admin token
_ensure() {
  ensure_day2
  [[ "$1" == 1 ]] && return 0
  [[ "$1" == 6 ]] && return 0
  autosync_off
  if [[ "$1" != 2 && "$1" != 3 ]] && [[ "$(catalog_env ADMIN_TOKEN)" != lab-token ]]; then
    oc -n "${SHOP_NS}" set env deployment/catalog ADMIN_TOKEN=lab-token >/dev/null
    oc -n "${SHOP_NS}" rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
  fi
  return 0
}

# the refresh after the push in task 6
REFRESH_CMD="oc -n \$NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite"

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Your starting point – auto-sync off"
  _ensure 1

  run "oc -n \$NS get applications.argoproj.io shop-dev"
  run "oc get pods"
  run "echo https://\$(oc get route web -o jsonpath='{.spec.host}')"
  run "oc -n \$NS get applications.argoproj.io shop-dev -o jsonpath='{.spec.syncPolicy}{\"\\n\"}'"
  if autosync_on; then
    run "oc -n \$NS patch applications.argoproj.io shop-dev --type=json -p '[{\"op\": \"remove\", \"path\": \"/spec/syncPolicy/automated\"}]'"
  else
    comment "Auto-sync is already off"
  fi
  run "oc -n \$NS get applications.argoproj.io shop-dev -o jsonpath='{.spec.syncPolicy}{\"\\n\"}'"

  discuss \
    "Argo CD only watches now" \
    "" \
    "Without automated: no self heal - oc set / patch / rollout undo stay." \
    "Argo CD still compares and shows OutOfSync - it just does not act." \
    "Fine for experiments, never for a real environment."
}

task2() {
  section "Task 2 · Read the probes"
  _ensure 2

  run "oc get deployment catalog -o yaml | grep -A8 -E '^ +(startupProbe|readinessProbe|livenessProbe):'"

  discuss \
    "Three probes, three reactions" \
    "" \
    "  startup     /health/started  2 s x 30   until ok: the others wait" \
    "  readiness   /health/ready    5 s x 2    no -> out of the Service" \
    "  liveness    /health/live     10 s x 3   no -> restart" \
    "" \
    "/health/live never checks dependencies - a restart would not help."
}

task3() {
  section "Task 3 · Unready, not dead"
  _ensure 3

  run "oc set env deployment/catalog ADMIN_TOKEN=lab-token"
  run "oc rollout status deployment/catalog --timeout=180s"

  show_file files/fault.sh
  run "./files/fault.sh '{\"fail_ready\": true}'"
  wait_until "catalog not ready" 60 \
    "[[ \$(oc get pods -l ${SEL} -o jsonpath='{.items[0].status.containerStatuses[0].ready}') == false ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc get endpointslice -l kubernetes.io/service-name=catalog -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}  ready={.conditions.ready}{\"\\n\"}{end}'"
  run "oc get events --field-selector reason=Unhealthy | tail -3"
  comment "Reload the shop in the browser – catalog is unreachable"
  pause

  run "./files/fault.sh '{\"fail_ready\": false}'"
  wait_until "catalog ready again" 60 \
    "[[ \$(oc get pods -l ${SEL} -o jsonpath='{.items[0].status.containerStatuses[0].ready}') == true ]]" || true
  run "oc get pods -l ${SEL}"

  discuss \
    "Readiness decides about traffic - not about restarts" \
    "" \
    "READY 0/1, RESTARTS 0, EndpointSlice ready=false." \
    "One replica: unready = nobody serves. Two: nobody notices."
}

task4() {
  section "Task 4 · A wrong liveness probe"
  _ensure 4

  run "oc patch deployment catalog -p '{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"catalog\",\"livenessProbe\":{\"httpGet\":{\"path\":\"/health/livez\"}}}]}}}}'"
  wait_until "the first liveness restart" 180 "[[ \$(restarts) -ge 1 ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc get events --field-selector reason=Unhealthy | grep -i liveness | tail -3"
  run "oc get events --field-selector reason=Killing | tail -3"
  run "oc -n \$NS get applications.argoproj.io shop-dev"
  pause

  run "oc rollout history deployment/catalog"
  run "oc rollout undo deployment/catalog"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc get pods -l ${SEL}"

  discuss \
    "A healthy app, killed by its own probe" \
    "" \
    "404 on /health/livez - 3 x 10 s - restart - again and again." \
    "The rollout looked fine: readiness was ok. shop-dev: OutOfSync." \
    "oc rollout undo works now - with auto-sync on: git revert."
}

task_slow() {
  section "Task 5a · Bonus: a slow start"
  _ensure slow

  run "oc set env deployment/catalog FAULT_STARTUP_DELAY_S=40"
  wait_until "the new Pod starting (0/1 next to 1/1)" 90 \
    "[[ \$(oc get pods -l ${SEL} --no-headers 2>/dev/null | wc -l) -ge 2 ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc get events --field-selector reason=Unhealthy | grep -i startup | tail -3"
  run "oc get pods -l ${SEL}"
  pause

  run "oc rollout undo deployment/catalog"
  run "oc rollout status deployment/catalog --timeout=180s"

  discuss \
    "Startup probe = the budget for a slow start" \
    "" \
    "40 s of 503 on /health/started, 60 s allowed - nothing killed." \
    "Old Pod serves until the new one is ready - the shop stays up."
}

task5() {     # both bonus tasks
  task_slow
  task_hpa
}

task_hpa() {
  section "Task 5b · Bonus: scale on load"
  _ensure hpa

  show_file files/hpa-catalog.yaml
  run "oc apply -f files/hpa-catalog.yaml"
  wait_until "the HPA at 2 replicas" 120 \
    "[[ \$(oc get hpa catalog -o jsonpath='{.status.currentReplicas}' 2>/dev/null) -ge 2 ]]" || true
  run "oc get hpa catalog"

  show_file files/load.yaml
  run "oc apply -f files/load.yaml"
  wait_until "the HPA scales out (above 2)" 300 \
    "[[ \$(oc get hpa catalog -o jsonpath='{.status.currentReplicas}' 2>/dev/null) -ge 3 ]]" || true
  run "oc get hpa catalog"
  run "oc get pods -l ${SEL}"
  run "oc adm top pods -l ${SEL}"
  run "oc delete -f files/load.yaml"

  discuss \
    "The HPA owns the replica count - Git must not" \
    "" \
    "Git still says replicas: 1 - with self heal on, the two would fight." \
    "Task 6 removes spec.replicas from Git (or: ignoreDifferences)." \
    "Load tools do not go to Git - oc apply, oc delete."
}

task6() {
  section "Task 6 · Back to Git – auto-sync on"
  _ensure 6

  run "oc delete -f files/load.yaml --ignore-not-found"
  show_file files/patch-catalog-lab.yaml
  run "diff \"\$SHOP_WORK/overlays/dev/kustomization.yaml\" files/kustomization-dev-hpa.yaml || true"
  run "cp files/patch-catalog-lab.yaml files/hpa-catalog.yaml \"\$SHOP_WORK/overlays/dev/\""
  run "cp files/kustomization-dev-hpa.yaml \"\$SHOP_WORK/overlays/dev/kustomization.yaml\""
  run "oc kustomize \"\$SHOP_WORK/overlays/dev\" | grep -E 'ADMIN_TOKEN|^kind: HorizontalPodAutoscaler'"
  run "git -C \"\$SHOP_WORK\" add ."
  run "git -C \"\$SHOP_WORK\" commit -m 'dev: admin token and HPA for catalog (lab 7)' || true"
  run "git -C \"\$SHOP_WORK\" push"
  run "oc -n \$NS patch applications.argoproj.io shop-dev --type=merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}'"
  run "${REFRESH_CMD}"
  wait_revision
  wait_app
  run "oc -n \$NS get applications.argoproj.io shop-dev"
  wait_until "the HPA at 2 replicas" 120 \
    "[[ \$(oc get hpa catalog -o jsonpath='{.status.currentReplicas}' 2>/dev/null) -ge 2 ]]" || true
  run "oc get hpa catalog"
  run "oc set env deployment/catalog --list | grep -E 'ADMIN_TOKEN|FAULT' || true"

  discuss \
    "Back to GitOps" \
    "" \
    "Admin token and HPA in Git, spec.replicas removed - self heal on again." \
    "Argo CD compares only what is in Git: oc leftovers can survive." \
    "Lab 8 continues from here."
}

bonus() {
  section "Bonus · two replicas, one unready"
  _ensure 6
  [[ "$(oc -n "${SHOP_NS}" get hpa catalog -o name 2>/dev/null)" ]] || task6
  comment "With 2+ catalog replicas: only one Pod unready – the shop does not notice"
  run "POD=\$(oc get pods -l ${SEL} -o jsonpath='{.items[0].metadata.name}'); echo \$POD"
  run "./files/fault.sh '{\"fail_ready\": true}' \$POD"
  wait_until "\$POD not ready" 60 \
    "[[ \$(oc get pod \$POD -o jsonpath='{.status.containerStatuses[0].ready}') == false ]]" || true
  run "oc get pods -l ${SEL}"
  run "./files/fault.sh '{\"fail_ready\": false}' \$POD"
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
  expect "auto-sync on again (task 6)" "true" \
    "$(oc -n "${NS}" get applications.argoproj.io shop-dev -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)"
  expect "catalog has an admin token (task 3/6)" "lab-token" \
    "$(_jp deployment/catalog '{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}')"
  expect "liveness path fixed (task 4)" "/health/live" \
    "$(_jp deployment/catalog '{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')"
  expect "no slow start left (task 5a)" "" \
    "$(_jp deployment/catalog '{.spec.template.spec.containers[0].env[?(@.name=="FAULT_STARTUP_DELAY_S")].value}')"
  expect "HPA catalog min 2" "2" "$(_jp hpa/catalog '{.spec.minReplicas}')"
  expect "HPA catalog max 6" "6" "$(_jp hpa/catalog '{.spec.maxReplicas}')"
  expect "catalog ready replicas >= 2" "yes" \
    "$([[ "$(_jp deployment/catalog '{.status.readyReplicas}')" -ge 2 ]] && echo yes || echo no)"
  expect "load generator removed" "no" \
    "$(oc -n "${SHOP_NS}" get deployment load >/dev/null 2>&1 && echo yes || echo no)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  oc -n "${SHOP_NS}" delete -f "${LAB_DIR}/files/load.yaml" --ignore-not-found >/dev/null 2>&1 || true
  if [[ "${OWN_PROJECTS}" == *" ${LAB_NS} "* ]]; then
    oc -n "${NS}" delete applications.argoproj.io shop-dev --ignore-not-found >/dev/null 2>&1 || true
    oc delete project "${SHOP_NS}" "${NS}" --ignore-not-found >/dev/null 2>&1 || true
    info "deleted the projects ${NS} and ${SHOP_NS}"
  else
    # a student's namespace: lab 8 continues with this state – only the lab tool goes
    info "removed the load generator in ${SHOP_NS} (the shop and its Application stay)"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
