# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 06 – shared tasks and checks.
#  Sourced by lab-06-walkthrough.sh (interactive) and lab-06-solve.sh
#  (automatic), all in lab-06/trainer/. The commands are the ones of the
#  student README; they run from lab-06/ with $NS, $SHOP_NS and $SHOP_WORK set.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created with an Argo CD
#              instance; the shop runs in LAB_NS-shop. Cleanup deletes both.)
#  Git:        GIT_REPO_URL       HTTPS URL of an EMPTY repository the trainer
#                                 owns – the scripts force-push to its branch main
#              GIT_USERNAME, GIT_TOKEN   credentials for push and for Argo CD
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-06-<namespace>)
# ---------------------------------------------------------------------------

# this file lives in lab-06/trainer/ – the lab files are one level up
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
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-06-${LAB_NS}}"
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
  if [[ $1 -ge 4 ]] && [[ ! -f "${SHOP_WORK}/overlays/dev/patch-catalog-lab.yaml" ]]; then
    cp files/patch-catalog-lab.yaml "${SHOP_WORK}/overlays/dev/"
    printf 'patches:\n- path: patch-catalog-lab.yaml\n' >> "${SHOP_WORK}/overlays/dev/kustomization.yaml"
    _commit_push "dev: admin token for catalog (lab 6)"
    wait_revision
    oc -n "${SHOP_NS}" rollout status deployment/catalog --timeout=180s >/dev/null 2>&1 || true
  fi
  return 0
}

# the step after every push in the README
REFRESH_CMD="oc -n \$NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite"

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Your starting point"
  _ensure 1

  run "oc -n \$NS get applications.argoproj.io shop-dev"
  run "oc get pods"
  run "echo https://\$(oc get route web -o jsonpath='{.spec.host}')"

  discuss \
    "The shop from Git - in its own namespace" \
    "" \
    "Application shop-dev in \$NS (next to Argo CD) -> objects in \$NS-shop." \
    "From now on: no oc edit / scale / set - self heal undoes it." \
    "Every change is a commit."
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

  if [[ ! -f "${SHOP_WORK}/overlays/dev/patch-catalog-lab.yaml" ]]; then
    show_file files/patch-catalog-lab.yaml
    run "cp files/patch-catalog-lab.yaml \"\$SHOP_WORK/overlays/dev/\""
    run "printf 'patches:\\n- path: patch-catalog-lab.yaml\\n' >> \"\$SHOP_WORK/overlays/dev/kustomization.yaml\""
    run "oc kustomize \"\$SHOP_WORK/overlays/dev\" | grep -A1 ADMIN_TOKEN"
    run "git -C \"\$SHOP_WORK\" add ."
    run "git -C \"\$SHOP_WORK\" commit -m 'dev: admin token for catalog (lab 6)'"
    run "git -C \"\$SHOP_WORK\" push"
    run "${REFRESH_CMD}"
    wait_revision
    run "oc rollout status deployment/catalog --timeout=180s"
  else
    comment "The admin token is already in Git (patch-catalog-lab.yaml)"
  fi

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
    "One replica: unready = nobody serves. Two: nobody notices." \
    "shop-dev stays Synced - nothing in Git changed."
}

task4() {
  section "Task 4 · A wrong liveness probe"
  _ensure 4

  run "diff files/patch-catalog-lab.yaml files/patch-catalog-typo.yaml"
  run "cp files/patch-catalog-typo.yaml \"\$SHOP_WORK/overlays/dev/patch-catalog-lab.yaml\""
  run "git -C \"\$SHOP_WORK\" commit -am 'dev: new liveness path'"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
  wait_until "the first liveness restart" 180 "[[ \$(restarts) -ge 1 ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc get events --field-selector reason=Unhealthy | grep -i liveness | tail -3"
  run "oc get events --field-selector reason=Killing | tail -3"
  pause

  run "git -C \"\$SHOP_WORK\" revert --no-edit HEAD"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc get pods -l ${SEL}"

  discuss \
    "A healthy app, killed by its own probe" \
    "" \
    "404 on /health/livez - 3 x 10 s - restart - again and again." \
    "The rollout looked fine: readiness was ok." \
    "Roll back with git revert - auto-sync stays on."
}

task5() {
  section "Task 5 · A slow start"
  _ensure 5

  run "diff files/patch-catalog-lab.yaml files/patch-catalog-slow.yaml"
  run "cp files/patch-catalog-slow.yaml \"\$SHOP_WORK/overlays/dev/patch-catalog-lab.yaml\""
  run "git -C \"\$SHOP_WORK\" commit -am 'dev: catalog starts slowly'"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
  wait_until "the new Pod starting (0/1 next to 1/1)" 90 \
    "[[ \$(oc get pods -l ${SEL} --no-headers 2>/dev/null | wc -l) -ge 2 ]]" || true
  run "oc get pods -l ${SEL}"
  run "oc rollout status deployment/catalog --timeout=180s"
  run "oc get events --field-selector reason=Unhealthy | grep -i startup | tail -3"
  run "oc get pods -l ${SEL}"
  pause

  run "git -C \"\$SHOP_WORK\" revert --no-edit HEAD"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
  run "oc rollout status deployment/catalog --timeout=180s"

  discuss \
    "Startup probe = the budget for a slow start" \
    "" \
    "40 s of 503 on /health/started, 60 s allowed - nothing killed." \
    "Old Pod serves until the new one is ready - the shop stays up."
}

task6() {
  section "Task 6 · Scale on load"
  _ensure 6

  show_file files/hpa-catalog.yaml
  run "cp files/hpa-catalog.yaml \"\$SHOP_WORK/overlays/dev/\""
  run "cp files/kustomization-dev-hpa.yaml \"\$SHOP_WORK/overlays/dev/kustomization.yaml\""
  run "oc kustomize \"\$SHOP_WORK/overlays/dev\" | grep -E '^kind: HorizontalPodAutoscaler|replicas:'"
  run "git -C \"\$SHOP_WORK\" add ."
  run "git -C \"\$SHOP_WORK\" commit -m 'dev: HPA for catalog, replicas no longer in Git'"
  run "git -C \"\$SHOP_WORK\" push"
  run "${REFRESH_CMD}"
  wait_revision
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
  run "oc -n \$NS get applications.argoproj.io shop-dev"
  run "oc delete -f files/load.yaml"

  discuss \
    "The HPA owns the replica count - Git must not" \
    "" \
    "The JSON patch removes spec.replicas: no fight with self heal." \
    "Alternative: ignoreDifferences on /spec/replicas in the Application." \
    "Load tools do not go to Git - oc apply, oc delete."
}

bonus() {
  section "Bonus · two replicas, one unready"
  _ensure 6
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
  expect "catalog has an admin token (task 3)" "lab-token" \
    "$(_jp deployment/catalog '{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_TOKEN")].value}')"
  expect "liveness path fixed (task 4)" "/health/live" \
    "$(_jp deployment/catalog '{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')"
  expect "no slow start left (task 5)" "" \
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
    # a student's namespace: lab 7 continues with this state – only the lab tool goes
    info "removed the load generator in ${SHOP_NS} (the shop and its Application stay)"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
