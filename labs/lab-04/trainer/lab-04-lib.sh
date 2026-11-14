# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 04 – shared tasks and checks.
#  Sourced by lab-04-walkthrough.sh (interactive) and lab-04-solve.sh
#  (automatic), all three in lab-04/trainer/. The layout is built step by
#  step in a work folder from the files in lab-04/reference/ – exactly the
#  files the students write in the README.
#
#  Namespace:  LAB_NS / -n NAME   (default: lab – created, deleted by cleanup)
#  Work dir:   WORK_DIR           (default: ${TMPDIR:-/tmp}/lab-04-<namespace>)
# ---------------------------------------------------------------------------

# this file lives in lab-04/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

OWN_PROJECTS=" lab "     # created by the lab -> cleanup deletes the project
FAILS=0
export REF="${LAB_DIR}/reference"   # shown as $REF in the commands

# lab_init – call after parse_demo_args: tools, login, work folder
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd curl
  require_oc_login
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/lab-04-${LAB_NS}}"
  mkdir -p "${WORK_DIR}"
  printf "%sFiles:  %s %s\n" "${C_BOLD}" "${C_RESET}" "${WORK_DIR}"
  cd "${WORK_DIR}" || die "Cannot cd to ${WORK_DIR}"
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

# _ensure STEP – a single task needs the files of the tasks before it:
# copy the finished state of the earlier tasks quietly from the reference
_ensure() {
  local step="$1"
  if [[ ${step} -ge 2 ]]; then
    mkdir -p base
    cp "${REF}"/base/* base/
  fi
  if [[ ${step} -ge 3 ]]; then
    mkdir -p overlays/dev
    cp "${REF}"/overlays/dev/* overlays/dev/
  fi
  if [[ ${step} -ge 4 ]]; then
    mkdir -p overlays/prod
    cp "${REF}"/overlays/prod/patch-resources.yaml overlays/prod/
  fi
  if [[ ${step} -ge 5 ]]; then
    mkdir -p components/pdb overlays/prod
    cp "${REF}"/components/pdb/* components/pdb/
    cp "${REF}"/overlays/prod/* overlays/prod/
  fi
  if [[ ${step} -ge 6 ]] && ! oc -n "${LAB_NS}" get deployment dev-website >/dev/null 2>&1; then
    oc -n "${LAB_NS}" apply -k overlays/dev >/dev/null
    oc -n "${LAB_NS}" apply -k overlays/prod >/dev/null
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · The base"
  rm -rf base overlays components

  run "mkdir -p base"
  run "cp \$REF/base/deployment.yaml \$REF/base/service.yaml \$REF/base/route.yaml \$REF/base/index.html base/"
  comment "The kustomization of task 1 – without the 'configurations' lines (task 2 adds them)"
  run "grep -v -e '^configurations:' -e '^- kustomizeconfig.yaml' \$REF/base/kustomization.yaml > base/kustomization.yaml"
  show_file base/kustomization.yaml
  pause
  run "oc kustomize base"

  discuss \
    "A base = plain YAML + kustomization.yaml" \
    "" \
    "  resources            the files that belong to it" \
    "  labels               part-of on everything - NOT on the selectors" \
    "  configMapGenerator   ConfigMap 'page' from index.html - with a hash" \
    "" \
    "deployment.yaml says configMap 'page' - the output says page-<hash>:" \
    "Kustomize rewrites every reference it knows."
}

task2() {
  section "Task 2 · Overlay dev – and a Route that points nowhere"
  _ensure 2
  cp "${REF}/base/kustomization.yaml" base/kustomization.yaml.full
  grep -v -e '^configurations:' -e '^- kustomizeconfig.yaml' base/kustomization.yaml.full > base/kustomization.yaml
  rm -f base/kustomization.yaml.full base/kustomizeconfig.yaml

  run "mkdir -p overlays/dev"
  run "cp \$REF/overlays/dev/index.html \$REF/overlays/dev/kustomization.yaml overlays/dev/"
  show_file overlays/dev/kustomization.yaml
  pause
  run "oc kustomize overlays/dev"

  comment "Look at the Route: it still points to 'website' – the Service is called 'dev-website'"
  run "oc kustomize overlays/dev | grep -A3 'to:'"
  pause

  comment "Teach Kustomize the reference Route -> Service – in the base, for every overlay"
  run "cp \$REF/base/kustomizeconfig.yaml \$REF/base/kustomization.yaml base/"
  show_file base/kustomizeconfig.yaml
  run "oc kustomize overlays/dev | grep -A3 'to:'"

  discuss \
    "namePrefix renames objects - and only the references it knows" \
    "" \
    "  renamed      ConfigMap in the volume, Service selector targets" \
    "  not renamed  Route spec.to.name, URLs in env, hosts in config files" \
    "" \
    "configurations + nameReference teaches Kustomize one more reference." \
    "" \
    "includeSelectors: true - env: dev is part of the selector:" \
    "dev and prod run in ONE namespace and must not share Pods."
}

task3() {
  section "Task 3 · Overlay prod – a transformer and a patch"
  _ensure 3

  run "mkdir -p overlays/prod"
  run "cp \$REF/overlays/prod/patch-resources.yaml overlays/prod/"
  comment "The kustomization of task 3 – without the component (task 4 adds it)"
  run "grep -v -e '^components:' -e 'components/pdb' \$REF/overlays/prod/kustomization.yaml > overlays/prod/kustomization.yaml"
  show_file overlays/prod/kustomization.yaml
  show_file overlays/prod/patch-resources.yaml
  pause
  run "oc kustomize overlays/prod | grep -E 'name: prod-|replicas:|cpu:|memory:'"

  discuss \
    "An overlay only contains the differences" \
    "" \
    "  replicas     a field - no patch needed" \
    "  patches      strategic merge: looks like the Deployment," \
    "               the container is matched by its name 'nginx'" \
    "" \
    "Patches and replicas use the BASE names (website) -" \
    "the prefix is added afterwards."
}

task4() {
  section "Task 4 · A component – the PodDisruptionBudget"
  _ensure 4

  run "mkdir -p components/pdb"
  run "cp \$REF/components/pdb/pdb.yaml \$REF/components/pdb/kustomization.yaml components/pdb/"
  show_file components/pdb/kustomization.yaml
  run "cp \$REF/overlays/prod/kustomization.yaml overlays/prod/"
  run "grep -A1 components overlays/prod/kustomization.yaml"
  run "oc kustomize overlays/prod | grep -B2 -A8 'kind: PodDisruptionBudget'"

  discuss \
    "Overlays are environments, components are features" \
    "" \
    "kind: Component - included with 'components:' by the overlays" \
    "that want it. The overlay's prefix and labels apply to it too:" \
    "prod-website, selector with env: prod." \
    "dev does not include it - dev has no PodDisruptionBudget."
}

task5() {
  section "Task 5 · Preview and apply – dev and prod side by side"
  _ensure 5

  comment "Exit code 1 from oc diff just means: there are differences"
  run "oc diff -k overlays/dev | head -40"
  run "oc apply -k overlays/dev"
  run "oc apply -k overlays/prod"
  run "oc get deployment,service,route,configmap,pdb -l 'env in (dev,prod)'"
  run "oc rollout status deployment/dev-website --timeout=120s"
  run "oc rollout status deployment/prod-website --timeout=120s"

  wait_until "the router serves both Routes" 60 \
    "[[ \$(route_code dev-website) == 200 && \$(route_code prod-website) == 200 ]]" || true
  run "curl -k -s https://\$(oc get route dev-website -o jsonpath='{.spec.host}')"
  run "curl -k -s https://\$(oc get route prod-website -o jsonpath='{.spec.host}')"

  discuss \
    "One base, two variants, one namespace" \
    "" \
    "Kept apart by the name prefix and the env selector." \
    "oc diff -k before every apply - it shows exactly what will change."
}

task6() {
  section "Task 6 · Change the page – only dev rolls out"
  _ensure 6

  run "printf '<html>\\n  <body>\\n    <h1>Hello from DEV - version 2</h1>\\n  </body>\\n</html>\\n' > overlays/dev/index.html"
  run "oc diff -k overlays/dev | grep -E '^[-+] .*(name: dev-page|<h1>)'"
  run "oc apply -k overlays/dev"
  run "oc rollout status deployment/dev-website --timeout=120s"
  wait_until "the new page" 60 "[[ \$(curl -ks \$(route_url dev-website)) == *'version 2'* ]]" || true
  run "curl -k -s https://\$(oc get route dev-website -o jsonpath='{.spec.host}')"
  run "oc get pods -l 'env in (dev,prod)'"
  run "oc get configmap -l env=dev"

  discuss \
    "New page -> new hash -> new ConfigMap name -> new Pod template" \
    "" \
    "A rolling update without oc rollout restart - only in dev." \
    "prod uses another ConfigMap: its Pods keep their age." \
    "" \
    "Two dev ConfigMaps now: oc apply -k never deletes." \
    "Argo CD can prune the old one (module 05)."
}

bonus() {
  section "Bonus · no pruning, pin by digest"
  _ensure 6

  comment "Remove the component from prod – is the PodDisruptionBudget gone?"
  run "grep -v -e '^components:' -e 'components/pdb' overlays/prod/kustomization.yaml > overlays/prod/k.yaml && mv overlays/prod/k.yaml overlays/prod/kustomization.yaml"
  run "oc apply -k overlays/prod"
  run "oc get pdb"
  run "oc delete pdb prod-website"

  comment "The digest of the image – for an images: entry with digest"
  run "oc image info quay.io/nginx/nginx-unprivileged:1.29.1 --filter-by-os=linux/amd64 | grep -i digest"

  discuss \
    "oc apply -k adds and changes - it never deletes" \
    "" \
    "Removed from the kustomization = still in the cluster." \
    "Delete by hand, or let Argo CD prune (module 05)." \
    "" \
    "images: with digest pins exactly one image - a re-pushed tag" \
    "cannot change what runs (lab 1)."
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
  expect "dev-website ready (1 replica)" "1" "$(_jp deployment/dev-website '{.status.readyReplicas}')"
  expect "prod-website ready (2 replicas)" "2" "$(_jp deployment/prod-website '{.status.readyReplicas}')"
  expect "dev selector has env=dev" "dev" "$(_jp deployment/dev-website '{.spec.selector.matchLabels.env}')"
  expect "dev Route → Service dev-website" "dev-website" "$(_jp route/dev-website '{.spec.to.name}')"
  expect "prod Route → Service prod-website" "prod-website" "$(_jp route/prod-website '{.spec.to.name}')"
  expect "prod has resource limits" "128Mi" "$(_jp deployment/prod-website '{.spec.template.spec.containers[0].resources.limits.memory}')"
  expect "dev page from a generated ConfigMap" "yes" \
    "$([[ "$(_jp deployment/dev-website '{.spec.template.spec.volumes[0].configMap.name}')" == dev-page-* ]] && echo yes || echo no)"
  expect "dev Route answers" "200" "$(route_code dev-website)"
  expect "prod Route answers" "200" "$(route_code prod-website)"
  expect "dev serves its own page" "yes" \
    "$([[ "$(curl -ks -m 5 "$(route_url dev-website)" 2>/dev/null)" == *DEV* ]] && echo yes || echo no)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  if [[ "${OWN_PROJECTS}" == *" ${LAB_NS} "* ]]; then
    oc delete project "${LAB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    info "deleted project ${LAB_NS}"
  else
    oc -n "${LAB_NS}" delete deployment,service,route -l 'env in (dev,prod),app.kubernetes.io/name=website' \
      --ignore-not-found >/dev/null 2>&1 || true
    oc -n "${LAB_NS}" delete configmap -l 'env in (dev,prod),app.kubernetes.io/part-of=website' \
      --ignore-not-found >/dev/null 2>&1 || true
    oc -n "${LAB_NS}" delete pdb prod-website --ignore-not-found >/dev/null 2>&1 || true
    info "deleted the lab objects in ${LAB_NS} (project kept)"
  fi
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
  info "removed the work folder"
}
