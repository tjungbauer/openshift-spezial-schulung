# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 05 – shared tasks and checks.
#  Sourced by lab-05-walkthrough.sh (interactive) and lab-05-solve.sh
#  (automatic), all in lab-05/trainer/. The commands are the ones of the
#  student README; they run from lab-05/ with $NS, $REPO_URL and $WORK set.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created, deleted by cleanup)
#  Git:        GIT_REPO_URL       HTTPS URL of an EMPTY repository the trainer
#                                 owns – the scripts force-push to its branch main
#              GIT_USERNAME, GIT_TOKEN   credentials for push and for Argo CD
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-05-<namespace>)
# ---------------------------------------------------------------------------

# this file lives in lab-05/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

OWN_PROJECTS=" lab "     # created by the lab -> cleanup deletes the project
FAILS=0
IMAGE="quay.io/nginx/nginx-unprivileged"

# lab_init – call after parse_demo_args: tools, login, Git, Argo CD instance
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd curl git sed
  require_oc_login
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-05-${LAB_NS}}"
  mkdir -p "${WORK_DIR}"

  # the variables of the student README
  export NS="${LAB_NS}"
  export WORK="${WORK_DIR}/website-gitops"
  export REPO_URL="${GIT_REPO_URL:-}"
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

  printf "%sRepo:   %s %s\n" "${C_BOLD}" "${C_RESET}" "${REPO_URL:-<not set>}"
  printf "%sFiles:  %s %s\n" "${C_BOLD}" "${C_RESET}" "${WORK}"
  cd "${LAB_DIR}" || die "Cannot cd to ${LAB_DIR}"
}

# need_repo – tasks that push need GIT_REPO_URL
need_repo() {
  [[ -n "${REPO_URL}" ]] || die "Set GIT_REPO_URL (HTTPS URL of an empty repository), GIT_USERNAME and GIT_TOKEN."
}

# ensure_argocd – the instance argocd in LAB_NS (the setup script does this for students)
ensure_argocd() {
  oc get crd argocds.argoproj.io >/dev/null 2>&1 \
    || die "No ArgoCD CRD – the OpenShift GitOps operator is not installed."
  if ! oc -n "${LAB_NS}" get argocd argocd >/dev/null 2>&1; then
    info "creating the Argo CD instance in ${LAB_NS} (trainer/lab-05-setup.sh does this for students)"
    oc -n "${LAB_NS}" apply -f "${LAB_DIR}/trainer/argocd.yaml" >/dev/null
  fi
  wait_until "the Argo CD server" 300 \
    "oc -n '${LAB_NS}' rollout status deployment/argocd-server --timeout=5s" || true
}

route_url() {
  printf "https://%s" "$(oc -n "${LAB_NS}" get route "$1" -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# route_code NAME – HTTP code of the Route from this machine, "none" or "blocked"
route_code() {
  local c
  oc -n "${LAB_NS}" get route "$1" >/dev/null 2>&1 || { printf "none"; return 0; }
  c=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$(route_url "$1")" 2>/dev/null || true)
  [[ "${c}" =~ ^[1-5][0-9][0-9]$ ]] && printf "%s" "${c}" || printf "blocked"
}

# app_state APP – "<sync>/<health>" of an Application
app_state() {
  oc -n "${LAB_NS}" get applications.argoproj.io "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true
}

# refresh APP – make Argo CD look at Git now
refresh() {
  oc -n "${LAB_NS}" annotate applications.argoproj.io "$1" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# wait_app APP [STATE] [TIMEOUT] – until the Application is STATE (default Synced/Healthy)
wait_app() {
  local want="${2:-Synced/Healthy}"
  wait_until "$1 ${want}" "${3:-180}" "[[ \$(app_state $1) == '${want}' ]]" || true
}

# wait_revision APP – until Argo CD has synced the commit HEAD of the work repo
wait_revision() {
  local head
  head="$(git -C "${WORK}" rev-parse HEAD)"
  wait_until "$1 at ${head:0:7}" 180 \
    "{ refresh $1; [[ \$(oc -n '${LAB_NS}' get applications.argoproj.io $1 -o jsonpath='{.status.sync.revision}') == '${head}' ]]; }" || true
}

_apply_app() {   # _apply_app dev|prod
  sed -e "s|<NS>|${NS}|g" -e "s|<REPO_URL>|${REPO_URL}|" "application-$1.yaml" | oc -n "${LAB_NS}" apply -f - >/dev/null
}

_repo_secret() {
  oc -n "${LAB_NS}" get secret website-gitops-repo >/dev/null 2>&1 && return 0
  oc -n "${LAB_NS}" create secret generic website-gitops-repo \
    --from-literal=type=git --from-literal=url="${REPO_URL}" \
    --from-literal=username="${GIT_USER}" --from-literal=password="${GIT_TOKEN}" >/dev/null
  oc -n "${LAB_NS}" label secret website-gitops-repo argocd.argoproj.io/secret-type=repository >/dev/null
}

_commit_push() {   # _commit_push "message"
  git -C "${WORK}" add .
  git -C "${WORK}" commit -q -m "$1" || true
  git -C "${WORK}" push -q --force -u origin main
}

# _ensure STEP – a single task needs the state of the tasks before it
_ensure() {
  local step="$1"
  need_repo
  [[ ${step} -ge 2 ]] && ensure_argocd
  if [[ ${step} -ge 2 ]] && [[ ! -d "${WORK}/.git" ]]; then
    _init_repo
  fi
  if [[ ${step} -ge 3 ]] && [[ -z "$(app_state website-dev)" ]]; then
    _repo_secret
    _apply_app dev
    wait_app website-dev
  fi
  if [[ ${step} -ge 5 ]] && [[ ! -f "${WORK}/overlays/dev/presync-job.yaml" ]]; then
    cp files/presync-job.yaml files/patch-route-wave.yaml "${WORK}/overlays/dev/"
    cp reference/overlays/dev/kustomization.yaml "${WORK}/overlays/dev/"
    _commit_push "dev: PreSync hook and sync wave for the Route"
    wait_revision website-dev
    wait_app website-dev
  fi
  if [[ ${step} -ge 6 ]] && [[ -z "$(app_state website-prod)" ]]; then
    _pin_digest
    _commit_push "prod: promote the dev image by digest"
    _apply_app prod
    wait_app website-prod
  fi
  return 0
}

_init_repo() {
  rm -rf "${WORK}"
  mkdir -p "${WORK}"
  cp -r ../lab-04/reference/base ../lab-04/reference/overlays ../lab-04/reference/components "${WORK}/"
  git -C "${WORK}" init -q -b main
  git -C "${WORK}" config user.name "${NS}"
  git -C "${WORK}" config user.email "${NS}@training.example"
  git -C "${WORK}" remote add origin "${REPO_URL}"
  _commit_push "website: base, dev and prod overlays"
}

_digest() {
  oc -n "${LAB_NS}" get pod -l app.kubernetes.io/name=website,env=dev \
    -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null | cut -d@ -f2
}

_pin_digest() {
  local digest
  digest="$(_digest)"
  [[ "${digest}" == sha256:* ]] || die "No digest – is dev-website running? (oc get pods -l env=dev)"
  grep -q '^images:' "${WORK}/overlays/prod/kustomization.yaml" && return 0
  printf 'images:\n- name: %s\n  digest: %s\n' "${IMAGE}" "${digest}" >> "${WORK}/overlays/prod/kustomization.yaml"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Push the website to Git"
  need_repo
  comment "Lab 4 objects would be adopted by Argo CD – start clean"
  run "oc delete deployment,service,route,configmap,pdb -l app.kubernetes.io/part-of=website"
  rm -rf "${WORK}"

  run "mkdir -p \"\$WORK\""
  run "cp -r ../lab-04/reference/base ../lab-04/reference/overlays ../lab-04/reference/components \"\$WORK\"/"
  run "oc kustomize \"\$WORK/overlays/dev\" | grep -E '^kind|^  name'"
  run "git -C \"\$WORK\" init -b main"
  run "git -C \"\$WORK\" config user.name \"\$NS\""
  run "git -C \"\$WORK\" config user.email \"\$NS@training.example\""
  run "git -C \"\$WORK\" add ."
  run "git -C \"\$WORK\" commit -m 'website: base, dev and prod overlays'"
  run "git -C \"\$WORK\" remote add origin \"\$REPO_URL\""
  comment "--force only here: the trainer repository is reused – students push to an empty one"
  run "git -C \"\$WORK\" push -u --force origin main"

  discuss \
    "Git holds the desired state - nothing else" \
    "" \
    "No oc commands, no namespace: only base, overlays, components." \
    "Who applies it, and where, is decided by the Application." \
    "" \
    "git -C \$WORK - the students never change directories."
}

task2() {
  section "Task 2 · Your Argo CD – and an Application for dev"
  _ensure 2

  run "echo https://\$(oc get route argocd-server -o jsonpath='{.spec.host}')"
  run "oc extract secret/argocd-cluster --keys=admin.password --to=-"
  comment "Log in to the UI as admin – then the repository Secret and the Application"
  pause
  oc -n "${LAB_NS}" delete secret website-gitops-repo --ignore-not-found >/dev/null 2>&1 || true
  run "oc create secret generic website-gitops-repo --from-literal=type=git --from-literal=url=\"\$REPO_URL\" --from-literal=username=\"\$GIT_USER\" --from-literal=password=\"\$GIT_TOKEN\""
  run "oc label secret website-gitops-repo argocd.argoproj.io/secret-type=repository"
  show_file application-dev.yaml
  run "sed -e \"s|<NS>|\$NS|g\" -e \"s|<REPO_URL>|\$REPO_URL|\" application-dev.yaml | oc apply -f -"
  wait_app website-dev
  run "oc get applications.argoproj.io"
  run "oc get deployment,service,route"
  wait_until "the router serves dev-website" 60 "[[ \$(route_code dev-website) == 200 ]]" || true
  run "curl -k https://\$(oc get route dev-website -o jsonpath='{.spec.host}')"

  discuss \
    "One Application = one Git folder -> one namespace" \
    "" \
    "  source        repoURL, targetRevision main, path overlays/dev" \
    "  destination   kubernetes.default.svc = this cluster, namespace" \
    "  automated     prune + selfHeal" \
    "" \
    "The instance lives in the student namespace and manages only it." \
    "Private repository: a Secret with secret-type=repository."
}

task3() {
  section "Task 3 · Fight Argo CD – self heal"
  _ensure 3

  run "oc scale deployment/dev-website --replicas=5"
  run "oc get deployment dev-website"
  wait_until "self heal sets it back to 1" 60 \
    "[[ \$(oc -n '${LAB_NS}' get deployment dev-website -o jsonpath='{.spec.replicas}') == 1 ]]" || true
  run "oc get deployment dev-website"

  discuss \
    "Self heal: the cluster is reset to Git" \
    "" \
    "oc scale, oc edit, oc set image - all undone within seconds." \
    "The change belongs in Git: a commit, reviewed, with history."
}

task4() {
  section "Task 4 · Order the sync – a hook and a wave"
  _ensure 4

  show_file files/presync-job.yaml
  show_file files/patch-route-wave.yaml
  run "cp files/presync-job.yaml files/patch-route-wave.yaml \"\$WORK/overlays/dev/\""
  comment "The complete dev kustomization (the README writes it with a heredoc)"
  run "cp reference/overlays/dev/kustomization.yaml \"\$WORK/overlays/dev/\""
  show_file "${WORK}/overlays/dev/kustomization.yaml"
  run "oc kustomize \"\$WORK/overlays/dev\" | grep -E 'argocd.argoproj.io|^kind'"
  run "git -C \"\$WORK\" add ."
  run "git -C \"\$WORK\" commit -m 'dev: PreSync hook and sync wave for the Route'"
  run "git -C \"\$WORK\" push"
  run "oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite"
  wait_revision website-dev
  wait_app website-dev
  run "oc get job dev-prepare"
  run "oc logs job/dev-prepare"

  discuss \
    "Order by annotation - not by script" \
    "" \
    "  PreSync hook   runs first, the sync waits for the Job" \
    "  wave 0         everything without an annotation" \
    "  wave 1         the Route - after wave 0 is healthy" \
    "" \
    "BeforeHookCreation: the old Job is deleted before the next sync." \
    "Real life: database migrations in PreSync."
}

task5() {
  section "Task 5 · Promote to prod – by digest"
  _ensure 5

  run "DIGEST=\$(oc get pod -l app.kubernetes.io/name=website,env=dev -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | cut -d@ -f2)"
  run "echo \"\$DIGEST\""
  if grep -q '^images:' "${WORK}/overlays/prod/kustomization.yaml"; then
    comment "prod already has an images: entry – not appended again"
  else
    run "printf 'images:\\n- name: quay.io/nginx/nginx-unprivileged\\n  digest: %s\\n' \"\$DIGEST\" >> \"\$WORK/overlays/prod/kustomization.yaml\""
  fi
  run "oc kustomize \"\$WORK/overlays/prod\" | grep 'image:'"
  run "git -C \"\$WORK\" add ."
  run "git -C \"\$WORK\" commit -m 'prod: promote the dev image by digest'"
  run "git -C \"\$WORK\" push"
  run "sed -e \"s|<NS>|\$NS|g\" -e \"s|<REPO_URL>|\$REPO_URL|\" application-prod.yaml | oc apply -f -"
  wait_app website-prod
  run "oc get applications.argoproj.io"
  run "oc get deployment prod-website -o jsonpath='{.spec.template.spec.containers[0].image}{\"\\n\"}'"

  discuss \
    "Promotion = one reviewed line in the prod overlay" \
    "" \
    "imageID in the Pod status = what the node really pulled." \
    "images: with digest -> image@sha256:... - a re-pushed tag" \
    "cannot change prod. Nothing is rebuilt."
}

task6() {
  section "Task 6 · Break it – roll back with git revert"
  _ensure 6

  show_file files/patch-broken-probe.yaml
  run "cp files/patch-broken-probe.yaml \"\$WORK/overlays/dev/\""
  run "printf -- '- path: patch-broken-probe.yaml\\n' >> \"\$WORK/overlays/dev/kustomization.yaml\""
  run "git -C \"\$WORK\" add ."
  run "git -C \"\$WORK\" commit -m 'dev: new readiness probe'"
  run "git -C \"\$WORK\" push"
  run "oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite"
  wait_revision website-dev
  wait_app website-dev "Synced/Progressing" 90
  run "oc get pods -l app.kubernetes.io/name=website,env=dev"
  run "oc get applications.argoproj.io website-dev"
  run "curl -k -s -o /dev/null -w '%{http_code}\\n' https://\$(oc get route dev-website -o jsonpath='{.spec.host}')"
  pause

  run "git -C \"\$WORK\" revert --no-edit HEAD"
  run "git -C \"\$WORK\" push"
  run "oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite"
  wait_revision website-dev
  wait_app website-dev
  run "oc get pods -l app.kubernetes.io/name=website,env=dev"
  run "git -C \"\$WORK\" log --oneline"

  discuss \
    "The rolling update protected us - the revert fixed it" \
    "" \
    "The new Pod stayed 0/1, the old one kept serving (HTTP 200)." \
    "Argo CD: Synced but Progressing - Degraded after 10 minutes." \
    "" \
    "git revert = a new, reviewed commit; auto-sync stays on." \
    "oc rollout undo would be overwritten by self heal."
}

bonus() {
  section "Bonus · prune"
  _ensure 6

  comment "Remove the component from prod – Argo CD prunes the PodDisruptionBudget"
  run "grep -v -e '^components:' -e 'components/pdb' \"\$WORK/overlays/prod/kustomization.yaml\" > \"\$WORK/k.yaml\" && mv \"\$WORK/k.yaml\" \"\$WORK/overlays/prod/kustomization.yaml\""
  run "git -C \"\$WORK\" commit -am 'prod: no PodDisruptionBudget'"
  run "git -C \"\$WORK\" push"
  run "oc annotate applications.argoproj.io website-prod argocd.argoproj.io/refresh=normal --overwrite"
  wait_revision website-prod
  wait_until "the PDB is pruned" 60 "! oc -n '${LAB_NS}' get pdb prod-website" || true
  run "oc get pdb"

  discuss \
    "Prune: deleted in Git -> deleted in the cluster" \
    "" \
    "Lab 4: oc apply -k kept the PDB. Argo CD with prune: true removes it." \
    "Without prune: the app shows OutOfSync, the object stays."
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

_jp() { oc -n "${LAB_NS}" get "$1" -o jsonpath="$2" 2>/dev/null || true; }

check() {
  FAILS=0
  section "Checks for ${LAB_NS}"
  expect "Argo CD server runs" "1" "$(_jp deployment/argocd-server '{.status.readyReplicas}')"
  expect "repository Secret labelled" "repository" \
    "$(_jp secret/website-gitops-repo '{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
  expect "website-dev Synced/Healthy" "Synced/Healthy" "$(app_state website-dev)"
  expect "website-dev: auto-sync with self heal" "true" \
    "$(_jp applications.argoproj.io/website-dev '{.spec.syncPolicy.automated.selfHeal}')"
  expect "dev-website ready (1 replica, Git value)" "1" "$(_jp deployment/dev-website '{.status.readyReplicas}')"
  expect "PreSync hook Job completed" "1" "$(_jp job/dev-prepare '{.status.succeeded}')"
  expect "dev Route in sync wave 1" "1" \
    "$(_jp route/dev-website '{.metadata.annotations.argocd\.argoproj\.io/sync-wave}')"
  expect "no broken probe in dev" "/" \
    "$(_jp deployment/dev-website '{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')"
  expect "website-prod Synced/Healthy" "Synced/Healthy" "$(app_state website-prod)"
  expect "prod image pinned by digest" "yes" \
    "$([[ "$(_jp deployment/prod-website '{.spec.template.spec.containers[0].image}')" == *@sha256:* ]] && echo yes || echo no)"
  expect "prod-website ready (2 replicas)" "2" "$(_jp deployment/prod-website '{.status.readyReplicas}')"
  expect "dev Route answers" "200" "$(route_code dev-website)"
  expect "prod Route answers" "200" "$(route_code prod-website)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  if [[ "${OWN_PROJECTS}" == *" ${LAB_NS} "* ]]; then
    oc -n "${LAB_NS}" delete applications.argoproj.io website-dev website-prod \
      --ignore-not-found >/dev/null 2>&1 || true
    oc delete project "${LAB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    info "deleted project ${LAB_NS}"
  else
    # no deletion finalizer: deleting the Applications leaves the objects – delete them too
    oc -n "${LAB_NS}" delete applications.argoproj.io website-dev website-prod \
      --ignore-not-found >/dev/null 2>&1 || true
    oc -n "${LAB_NS}" delete deployment,service,route,configmap,pdb,job -l 'env in (dev,prod)' \
      --ignore-not-found >/dev/null 2>&1 || true
    oc -n "${LAB_NS}" delete secret website-gitops-repo --ignore-not-found >/dev/null 2>&1 || true
    info "deleted the lab objects in ${LAB_NS} (project and Argo CD instance kept)"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
