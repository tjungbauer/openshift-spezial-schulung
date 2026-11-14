# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 00 – shared setup, tasks and checks.
#  Sourced by lab-00-walkthrough.sh (interactive) and lab-00-solve.sh
#  (automatic), all three in lab-00/trainer/. Works on the lab files in
#  lab-00/ and uses the shared demo library from ../../demos/lib.
#
#  Namespaces – every student has two, e.g. sbx-ws01 and sbx-ws01-neighbour:
#     LAB_NS / -n NAME   the namespace with the app  (default: lab)
#     NEIGHBOUR_NS       the second namespace – plays "another team";
#                        only a toolbox runs there   (default: <LAB_NS>-neighbour)
#  lab and lab-neighbour are created with oc new-project and deleted by
#  cleanup. Other names (e.g. sbx-ws01 / sbx-ws01-neighbour) are only used,
#  never deleted – cleanup removes the lab objects in them.
# ---------------------------------------------------------------------------

# this file lives in lab-00/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

IMAGE="quay.io/nginx/nginx-unprivileged:1.29.1"
OWN_PROJECTS=" lab lab-neighbour "     # created by the lab -> cleanup deletes the project
LAB_TMP=""
FAILS=0

# lab_init – call after parse_demo_args: login, namespaces, temp dir
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  NEIGHBOUR_NS="${NEIGHBOUR_NS:-${LAB_NS}-neighbour}"
  [[ "${NEIGHBOUR_NS}" != "${LAB_NS}" ]] || die "LAB_NS and NEIGHBOUR_NS must be different."
  require_cmd curl
  require_oc_login
  printf "%sNeighbour:%s %s\n" "${C_BOLD}" "${C_RESET}" "${NEIGHBOUR_NS}"
  LAB_TMP="$(mktemp -d)"
  on_exit_always _lab_remove_tmp
  cd "${LAB_DIR}" || die "Cannot cd to ${LAB_DIR}"
}

_lab_remove_tmp() {
  [[ -n "${LAB_TMP}" ]] && rm -rf "${LAB_TMP}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Probes
# ═══════════════════════════════════════════════════════════════════════════

# code_from NS URL – HTTP code of a curl from the toolbox pod in NS, or "blocked"
code_from() {
  local c
  c=$(oc -n "$1" exec toolbox -- curl -s -o /dev/null -m 4 -w '%{http_code}' "$2" 2>/dev/null || true)
  [[ "${c}" =~ ^[1-5][0-9][0-9]$ ]] && printf "%s" "${c}" || printf "blocked"
}

route_url() {
  printf "https://%s" "$(oc -n "${1:-${LAB_NS}}" get route hello -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# route_code NS – HTTP code of the Route from this machine, "none" or "blocked"
route_code() {
  local c
  oc -n "$1" get route hello >/dev/null 2>&1 || { printf "none"; return 0; }
  c=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$(route_url "$1")" 2>/dev/null || true)
  [[ "${c}" =~ ^[1-5][0-9][0-9]$ ]] && printf "%s" "${c}" || printf "blocked"
}

# reach LABEL EXPECTED CMD... – run a probe (retry briefly until it matches),
# print one coloured line with ✔ as expected / ✘ expected …
reach() {
  local label="$1" expected="$2" result colour verdict try
  shift 2
  for try in 1 2 3; do
    result=$("$@")
    [[ "${result}" == "${expected}" ]] && break
    [[ ${try} -lt 3 ]] && sleep 2
  done
  case "${result}" in
    2*|3*)   colour="${C_OK}" ;;
    blocked) colour="${C_ERR}" ;;
    *)       colour="${C_WARN}" ;;
  esac
  if [[ "${result}" == "${expected}" ]]; then
    verdict="${C_DIM}✔ as expected${C_RESET}"
  else
    verdict="${C_ERR}✘ expected ${expected}${C_RESET}"
  fi
  printf "  %-46s %s%-8s%s %s\n" "${label}" "${colour}" "${result}" "${C_RESET}" "${verdict}"
}

# test_access OWN NEIGHBOUR ROUTE – who reaches my hello app?
test_access() {
  reach "${LAB_NS}/toolbox → hello:8080" "$1" code_from "${LAB_NS}" "http://hello:8080"
  reach "${NEIGHBOUR_NS}/toolbox → hello.${LAB_NS}.svc" "$2" code_from "${NEIGHBOUR_NS}" "http://hello.${LAB_NS}.svc:8080"
  reach "this machine → Route" "$3" route_code "${LAB_NS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Setup: the neighbour
# ═══════════════════════════════════════════════════════════════════════════

# setup_neighbour – make sure the second namespace exists. Students get it
# from the trainer (sbx-wsXX-neighbour); it stays empty until task 5 puts a
# toolbox into it. Nothing else runs there.
setup_neighbour() {
  local ns="${NEIGHBOUR_NS}"
  section "Setup · the second namespace ${ns}"
  if oc get project "${ns}" >/dev/null 2>&1; then
    info "Project ${ns} exists"
  else
    oc new-project "${ns}" --skip-config-write >/dev/null || die "Cannot create project ${ns}."
    success "Created project ${ns}"
  fi
}

# _ensure_neighbour – single tasks need the second namespace
_ensure_neighbour() {
  oc get project "${NEIGHBOUR_NS}" >/dev/null 2>&1 \
    || die "Namespace ${NEIGHBOUR_NS} not found – run '$(basename "$0") setup' or set NEIGHBOUR_NS."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Look around – quota, LimitRange, NetworkPolicies"

  run "oc describe project ${LAB_NS}"
  run "oc get quota,limitrange,networkpolicy"

  discuss \
    "What separates my namespace from my neighbour's?" \
    "" \
    "  ResourceQuota  caps the total CPU/memory/objects of a project" \
    "  LimitRange     default and maximum resources per container" \
    "  NetworkPolicy  who may talk to my pods - none = everybody" \
    "" \
    "RBAC keeps the neighbour out of my API objects." \
    "The NETWORK is open until we add NetworkPolicies (task 6)."
}

task2() {
  section "Task 2 · Configuration – a ConfigMap from a file, a Secret from a literal"

  comment "--dry-run=client -o yaml | oc apply -f -  works also when it already exists"
  run "oc create configmap hello-page --from-file=index.html --dry-run=client -o yaml | oc apply -f -"
  run "oc create secret generic hello-secret --from-literal=API_KEY=s3cr3t --dry-run=client -o yaml | oc apply -f -"

  comment "The Secret is only base64 encoded"
  run "oc extract secret/hello-secret --to=-"

  discuss \
    "ConfigMap: the web page   Secret: the API key" \
    "" \
    "Both keep configuration out of the image:" \
    "same image in dev/test/prod, different configuration." \
    "Secrets are base64 - protect them with RBAC (see demo 03)."
}

task3() {
  section "Task 3 · Deployment – generate, add Secret and ConfigMap, apply"

  comment "Generate the YAML instead of writing it from scratch"
  run "oc create deployment hello --image=${IMAGE} --port=8080 --dry-run=client -o yaml > ${LAB_TMP}/deployment.yaml"
  show_file "${LAB_TMP}/deployment.yaml"
  pause

  comment "Add env (from the Secret) and a volume (from the ConfigMap) – the finished file:"
  show_file reference/deployment.yaml
  pause

  run "oc apply -f reference/deployment.yaml"
  run "oc rollout status deployment/hello --timeout=120s"

  comment "The Secret value arrives as an environment variable"
  run "oc exec deploy/hello -- printenv API_KEY"

  discuss \
    "env.valueFrom.secretKeyRef  and  volumes.configMap" \
    "" \
    "API_KEY comes from the Secret, set when the container starts." \
    "index.html is mounted from the ConfigMap into the nginx docroot." \
    "" \
    "The generated YAML has no securityContext -> PodSecurity warning." \
    "The reference file adds it (optional, see demo 01): no warning."
}

task4() {
  section "Task 4 · Service and Route – then change the page"

  if oc get service hello >/dev/null 2>&1; then
    info "Service hello already exists"
  else
    run "oc expose deployment hello --port=8080"
  fi
  if oc get route hello >/dev/null 2>&1; then
    info "Route hello already exists"
  else
    run "oc create route edge hello --service=hello"
  fi

  wait_until "the router serves the Route" 60 "[[ \$(route_code ${LAB_NS}) == 200 ]]" || true
  run "curl -ks https://\$(oc get route hello -o jsonpath='{.spec.host}')"

  comment "Change the page and update the ConfigMap (plain ASCII – see the note below)"
  run "sed 's/Hello from Lab 0/Hello again - changed ConfigMap/' index.html > ${LAB_TMP}/index.html"
  run "(cd ${LAB_TMP} && oc set data configmap/hello-page --from-file=index.html)"

  comment "The mounted file follows within about a minute – no restart needed"
  wait_until "new page via the Route" 120 \
    "[[ \$(curl -ks \$(route_url ${LAB_NS})) == *'Hello again'* ]]" || true
  run "curl -ks https://\$(oc get route hello -o jsonpath='{.spec.host}')"

  discuss \
    "Service -> stable name, Route -> external HTTPS (edge TLS)" \
    "" \
    "oc set data replaces a key of the ConfigMap; the kubelet" \
    "updates the mounted file, nginx serves the new page." \
    "" \
    "Note: oc set data stores files with non-ASCII characters" \
    "(umlauts, en dash ...) under binaryData instead of data." \
    "The page still works - but '.data' is empty then."
}

task5() {
  section "Task 5 · Visit your neighbour – no isolation by default"
  _ensure_neighbour

  comment "One toolbox in each namespace – ${NEIGHBOUR_NS} plays another team"
  show_file toolbox.yaml
  run "oc apply -f toolbox.yaml"
  run "oc apply -n ${NEIGHBOUR_NS} -f toolbox.yaml"
  run "oc wait --for=condition=Ready pod/toolbox --timeout=120s"
  run "oc wait -n ${NEIGHBOUR_NS} --for=condition=Ready pod/toolbox --timeout=120s"

  comment "Same namespace: the short name is enough"
  run "oc exec toolbox -- curl -s -m 3 http://hello:8080"

  comment "From the other namespace: <service>.<namespace>.svc"
  run "oc -n ${NEIGHBOUR_NS} exec toolbox -- getent hosts hello.${LAB_NS}.svc"
  run "oc -n ${NEIGHBOUR_NS} exec toolbox -- curl -s -m 3 http://hello.${LAB_NS}.svc:8080"

  reach "${LAB_NS}/toolbox → hello:8080" 200 code_from "${LAB_NS}" "http://hello:8080"
  reach "${NEIGHBOUR_NS}/toolbox → hello.${LAB_NS}.svc" 200 code_from "${NEIGHBOUR_NS}" "http://hello.${LAB_NS}.svc:8080"

  discuss \
    "<service>.<namespace>.svc - and it just works" \
    "" \
    "Without NetworkPolicies every pod reaches every Service in" \
    "every namespace. RBAC decides who may SEE and CHANGE my" \
    "objects - not who may CALL my app."
}

task6() {
  section "Task 6 · Close your namespace – test after each policy"
  _ensure_neighbour
  if ! oc -n "${NEIGHBOUR_NS}" get pod toolbox >/dev/null 2>&1; then
    info "no toolbox in ${NEIGHBOUR_NS} yet – starting it (task 5)"
    oc -n "${NEIGHBOUR_NS}" apply -f toolbox.yaml >/dev/null
    oc -n "${NEIGHBOUR_NS}" wait --for=condition=Ready pod/toolbox --timeout=120s >/dev/null 2>&1 || true
  fi
  if ! oc -n "${LAB_NS}" get pod toolbox >/dev/null 2>&1; then
    oc -n "${LAB_NS}" apply -f toolbox.yaml >/dev/null
    oc -n "${LAB_NS}" wait --for=condition=Ready pod/toolbox --timeout=120s >/dev/null 2>&1 || true
  fi

  show_file default-deny.yaml
  run "oc apply -f default-deny.yaml"
  test_access blocked blocked 503
  pause

  show_file allow-same-namespace.yaml
  run "oc apply -f allow-same-namespace.yaml"
  test_access 200 blocked 503
  pause

  show_file allow-from-router.yaml
  run "oc apply -f allow-from-router.yaml"
  test_access 200 blocked 200
  run "oc get networkpolicy"

  discuss \
    "default-deny + allow-same-namespace + allow-from-router" \
    "" \
    "default-deny:          nobody gets in - even the router (503)" \
    "allow-same-namespace:  my own pods again" \
    "allow-from-router:     the Route again" \
    "" \
    "The other namespace stays out. Policies are additive allow-lists."
}

bonus() {
  section "Bonus · headless and NodePort Service, Route timeout"

  run "oc scale deployment/hello --replicas=2"
  run "oc rollout status deployment/hello --timeout=120s"
  run "oc apply -f hello-headless.yaml -f hello-nodeport.yaml"

  comment "Normal Service: ONE virtual IP – headless Service: every pod IP"
  run "oc exec toolbox -- getent hosts hello"
  run "oc exec toolbox -- getent hosts hello-headless"

  comment "NodePort: a port from 30000-32767 on every node"
  run "oc get service hello-nodeport -o jsonpath='{.spec.ports[0].nodePort}{\"\\n\"}'"

  run "oc explain route.spec.tls.termination | head -12"
  run "oc annotate route hello haproxy.router.openshift.io/timeout=30s --overwrite"

  discuss \
    "Service types" \
    "" \
    "  ClusterIP   virtual IP inside the cluster (default)" \
    "  headless    clusterIP: None - DNS returns the pod IPs" \
    "              (StatefulSets, client-side load balancing)" \
    "  NodePort    a port on every node - rarely needed with Routes" \
    "" \
    "Route annotations tune the router, e.g. the timeout."
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

# _cm_has_page – yes if hello-page has index.html, in .data OR .binaryData
# (oc set data puts non-ASCII files into binaryData)
_cm_has_page() {
  local data
  data="$(oc -n "${LAB_NS}" get configmap hello-page \
    -o jsonpath='{.data.index\.html}{.binaryData.index\.html}' 2>/dev/null || true)"
  [[ -n "${data}" ]] && printf "yes" || printf "no"
}

check() {
  local ready
  FAILS=0
  section "Checks for ${LAB_NS} (second namespace: ${NEIGHBOUR_NS})"
  ready="$(oc -n "${LAB_NS}" get deployment hello -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"

  expect "ConfigMap hello-page has index.html" "yes" "$(_cm_has_page)"
  expect "Secret hello-secret exists" "Opaque" \
    "$(oc -n "${LAB_NS}" get secret hello-secret -o jsonpath='{.type}' 2>/dev/null || true)"
  expect "Deployment hello ready" "yes" "$([[ "${ready:-0}" -ge 1 ]] && echo yes || echo no)"
  expect "Secret value in the container" "s3cr3t" \
    "$(oc -n "${LAB_NS}" exec deploy/hello -- printenv API_KEY 2>/dev/null || true)"
  expect "Service hello → port 8080" "8080" \
    "$(oc -n "${LAB_NS}" get service hello -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  expect "Route is edge-terminated" "edge" \
    "$(oc -n "${LAB_NS}" get route hello -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)"
  expect "Route answers" "200" "$(route_code "${LAB_NS}")"
  expect "NetworkPolicies in place" "allow-from-router allow-same-namespace default-deny" \
    "$(oc -n "${LAB_NS}" get networkpolicy -o name 2>/dev/null | sed 's#.*/##' | sort | xargs)"
  expect "own pod → hello:8080" "200" "$(code_from "${LAB_NS}" http://hello:8080)"
  expect "toolbox in ${NEIGHBOUR_NS} (task 5)" "Running" \
    "$(oc -n "${NEIGHBOUR_NS}" get pod toolbox -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  expect "no NetworkPolicy in ${NEIGHBOUR_NS}" "0" \
    "$(oc -n "${NEIGHBOUR_NS}" get networkpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  expect "${NEIGHBOUR_NS}/toolbox → my hello (blocked)" "blocked" \
    "$(code_from "${NEIGHBOUR_NS}" "http://hello.${LAB_NS}.svc:8080")"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

# cleanup – lab and lab-neighbour: delete the projects. Student namespaces
# (e.g. sbx-ws01 / sbx-ws01-neighbour): keep them, delete only the lab objects.
# The second namespace normally holds only the toolbox; the full list also
# removes leftovers of older lab versions, which put the app there as well.
cleanup() {
  local ns
  for ns in "${LAB_NS}" "${NEIGHBOUR_NS}"; do
    if [[ "${OWN_PROJECTS}" == *" ${ns} "* ]]; then
      oc delete project "${ns}" --ignore-not-found >/dev/null 2>&1 || true
      info "deleted project ${ns}"
    else
      oc -n "${ns}" delete networkpolicy default-deny allow-same-namespace allow-from-router \
        --ignore-not-found >/dev/null 2>&1 || true
      oc -n "${ns}" delete route/hello svc/hello svc/hello-headless svc/hello-nodeport deploy/hello \
        pod/toolbox configmap/hello-page secret/hello-secret --ignore-not-found --wait=false >/dev/null 2>&1 || true
      info "deleted the lab objects in ${ns} (project kept)"
    fi
  done
}
