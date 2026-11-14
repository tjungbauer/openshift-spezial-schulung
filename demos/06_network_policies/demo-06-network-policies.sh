#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 06 – Network isolation and egress
#  Run:     ./demo-06-network-policies.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in, curl
#  The demo runs in the project "demo" (or NAME), created if missing.
#  A second project "<NAME>-other" plays the neighbour (env OTHER_NS).
#  Step 6 (EgressFirewall) needs cluster-admin and is skipped otherwise.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-6); default: all steps
  cleanup                remove everything the demo created

  OTHER_NS=NAME          the neighbour project (default: <namespace>-other)"
parse_demo_args "$@"
cd "${SCRIPT_DIR}"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-6]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

OTHER_NS="${OTHER_NS:-${DEMO_PROJECT}-other}"
OTHER_MARKER="Neighbour project for demo 06"   # only projects with this description get deleted
WEB="http://web.${DEMO_PROJECT}.svc:8080"
EXTERNAL_OK="https://access.redhat.com"
EXTERNAL_DENIED="https://www.google.com"
POLICIES="default-deny allow-same-namespace allow-from-router client-egress"

# ═══════════════════════════════════════════════════════════════════════════
#  Reachability tests
# ═══════════════════════════════════════════════════════════════════════════

# _http_code FROM URL – HTTP code, or "blocked" if there is no answer.
# FROM is a namespace (curl from its client pod) or "laptop" (curl from here).
_http_code() {
  local code
  if [[ "$1" == "laptop" ]]; then
    code=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$2" 2>/dev/null || true)
  else
    code=$(oc -n "$1" exec client -- curl -s -o /dev/null -m 4 -w '%{http_code}' "$2" 2>/dev/null || true)
  fi
  [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]] && printf "%s" "${code}" || printf "blocked"
}

# _matches RESULT EXPECTED – EXPECTED is a code, "blocked" or "ok" (any answer < 500)
_matches() {
  case "$2" in
    ok) [[ "$1" =~ ^[1-4][0-9][0-9]$ ]] ;;
    *)  [[ "$1" == "$2" ]] ;;
  esac
}

# check FROM URL EXPECTED – test once, retry briefly if the result is not
# the expected one yet (policies need a moment), then print one result line
check() {
  local from="$1" url="$2" expected="$3" result colour label verdict try
  for try in 1 2 3; do
    result=$(_http_code "${from}" "${url}")
    _matches "${result}" "${expected}" && break
    [[ ${try} -lt 3 ]] && sleep 2
  done
  case "${result}" in
    2*|3*)   colour="${C_OK}" ;;
    blocked) colour="${C_ERR}" ;;
    *)       colour="${C_WARN}" ;;
  esac
  if [[ "${from}" == "laptop" ]]; then label="this machine"; else label="${from}/client"; fi
  if _matches "${result}" "${expected}"; then
    verdict="${C_DIM}✔ as expected${C_RESET}"
  else
    verdict="${C_ERR}✘ expected ${expected}${C_RESET}"
  fi
  printf "  %-24s → %-44s %s%-8s%s %s\n" "${label}" "${url}" "${colour}" "${result}" "${C_RESET}" "${verdict}"
}

route_url() {
  printf "https://%s" "$(oc get route web -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# test_access OWN OTHER ROUTE – who can reach the web app?
test_access() {
  comment "Who can reach the web app? (curl from both client pods and from this machine)"
  check "${DEMO_PROJECT}" "${WEB}" "$1"
  check "${OTHER_NS}" "${WEB}" "$2"
  check laptop "$(route_url)" "$3"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  if [[ "$(oc auth can-i delete egressfirewalls.k8s.ovn.org -n "${DEMO_PROJECT}" 2>/dev/null || true)" == "yes" ]]; then
    delete_quietly egressfirewall default
  fi
  # shellcheck disable=SC2086  # word splitting of POLICIES is intended
  delete_quietly networkpolicy ${POLICIES}
  delete_quietly route web
  delete_quietly service web
  delete_quietly deployment web
  delete_quietly pod client
  # the neighbour project – only if this demo created it
  if [[ "$(oc get project "${OTHER_NS}" -o jsonpath='{.metadata.annotations.openshift\.io/description}' 2>/dev/null || true)" == "${OTHER_MARKER}" ]]; then
    oc delete project "${OTHER_NS}" --ignore-not-found >/dev/null 2>&1 || true
  else
    oc -n "${OTHER_NS}" delete pod client --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · Setup: web app in ${DEMO_PROJECT}, a client pod in both projects"

  if ! oc get project "${OTHER_NS}" >/dev/null 2>&1; then
    comment "Create the neighbour project (--skip-config-write: stay in ${DEMO_PROJECT})"
    run "oc new-project ${OTHER_NS} --skip-config-write --description='${OTHER_MARKER}'"
  fi

  comment "The web app: Deployment + Service + edge Route"
  show_file app.yaml
  comment "A client pod with curl – one in each project"
  show_file client.yaml
  pause

  run "oc apply -f app.yaml -f client.yaml"
  run "oc -n ${OTHER_NS} apply -f client.yaml"
  run "oc rollout status deployment/web --timeout=120s"
  run "oc wait --for=condition=Ready pod/client --timeout=120s"
  run "oc -n ${OTHER_NS} wait --for=condition=Ready pod/client --timeout=120s"
}

step1() {
  section "1 · No NetworkPolicy: everybody reaches everybody"

  run "oc get networkpolicy"
  test_access 200 200 200

  discuss \
    "By default the pod network is flat" \
    "" \
    "Without NetworkPolicies every pod can reach every other pod" \
    "in the cluster - across all projects." \
    "" \
    "Projects separate names, RBAC and quotas - NOT network traffic." \
    "Isolation has layers: RBAC, SCC, quotas ... and NetworkPolicy."
}

step2() {
  section "2 · default-deny: the project is closed – for everyone"

  show_file np-default-deny.yaml
  run "oc apply -f np-default-deny.yaml"
  test_access blocked blocked 503

  discuss \
    "podSelector: {}  +  no ingress rules  =  deny all ingress" \
    "" \
    "As soon as ANY policy selects a pod, only traffic that some" \
    "policy allows gets in. Policies are additive allow-lists." \
    "" \
    "Even the OpenShift router is locked out:" \
    "the Route answers 503 - the router cannot reach the pod."
}

step3() {
  section "3 · allow-same-namespace: own pods yes, the neighbour no"

  show_file np-allow-same-namespace.yaml
  run "oc apply -f np-allow-same-namespace.yaml"
  test_access 200 blocked 503

  discuss \
    "from: - podSelector: {}" \
    "" \
    "A podSelector without namespaceSelector means: pods of the" \
    "SAME namespace. The neighbour project stays locked out." \
    "" \
    "The router lives in another namespace -> still 503."
}

step4() {
  section "4 · allow-from-router: the Route works again"

  show_file np-allow-from-router.yaml
  run "oc apply -f np-allow-from-router.yaml"
  test_access 200 blocked 200
  run "oc get networkpolicy"

  discuss \
    "namespaceSelector: policy-group.network.openshift.io/ingress" \
    "" \
    "OpenShift labels the namespace(s) of the ingress routers with" \
    "this policy group - also when the routers run in host network." \
    "" \
    "Typical baseline for every project:" \
    "  default-deny + allow-same-namespace + allow-from-router" \
    "(+ allow-from-openshift-monitoring if you expose metrics)"
}

step5() {
  section "5 · Egress NetworkPolicy: the client may use DNS and the web app – nothing else"

  comment "Before: the client can reach the internet"
  check "${DEMO_PROJECT}" "${EXTERNAL_OK}" ok

  show_file np-client-egress.yaml
  run "oc apply -f np-client-egress.yaml"

  comment "After: the web app yes, the internet no"
  check "${DEMO_PROJECT}" "${WEB}" 200
  check "${DEMO_PROJECT}" "${EXTERNAL_OK}" blocked

  comment "DNS still works – only the connection is blocked"
  run "oc exec client -- getent hosts access.redhat.com"

  discuss \
    "policyTypes: [Egress]" \
    "" \
    "Egress rules restrict what the SELECTED pods may connect to." \
    "Once egress is restricted, DNS must be allowed explicitly:" \
    "  port 53 = Service port, 5353 = port of the DNS pods" \
    "  (NetworkPolicy sees the pod port after the Service DNAT)" \
    "" \
    "NetworkPolicy knows pods, namespaces and IP blocks - but no" \
    "DNS names. For that: EgressFirewall (next step)."
}

step6() {
  section "6 · EgressFirewall (cluster-admin): which external targets may the project reach?"

  if [[ "$(oc auth can-i create egressfirewalls.k8s.ovn.org -n "${DEMO_PROJECT}" 2>/dev/null || true)" != "yes" ]]; then
    warn "Skipped – you may not create EgressFirewalls in ${DEMO_PROJECT} (needs cluster-admin)."
    return 0
  fi

  comment "Remove the egress NetworkPolicy, so only the EgressFirewall decides"
  run "oc delete networkpolicy client-egress --ignore-not-found"

  show_file egressfirewall.yaml
  run "oc apply -f egressfirewall.yaml"
  run "oc get egressfirewall"

  check "${DEMO_PROJECT}" "${EXTERNAL_OK}" ok
  check "${DEMO_PROJECT}" "${EXTERNAL_DENIED}" blocked
  comment "Traffic inside the cluster is not affected by the EgressFirewall"
  check "${DEMO_PROJECT}" "${WEB}" 200

  discuss \
    "EgressFirewall (OVN-Kubernetes)" \
    "" \
    "  - one per namespace, always named 'default'" \
    "  - rules by CIDR or DNS name, first match wins" \
    "  - applies only to traffic LEAVING the cluster" \
    "  - created by cluster-admins: the project cannot loosen it" \
    "" \
    "NetworkPolicy: owned by the project team, pod/namespace level" \
    "EgressFirewall: owned by the platform team, external targets"
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
require_cmd curl
require_oc_login
printf "%sNeighbour:%s %s\n" "${C_BOLD}" "${C_RESET}" "${OTHER_NS}"

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [0-6])
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    on_exit_cleanup cleanup "Delete demo 06 resources (policies block other demos)? [y/N]"

    title "Demo 06 – Network isolation and egress" "default-deny · same-namespace · router · egress"
    for i in 0 1 2 3 4 5 6; do "step${i}"; done

    takeaways \
      "Projects do not isolate network traffic – NetworkPolicies do" \
      "Start with default-deny, then allow what is needed" \
      "Allow the router namespace, or Routes answer 503" \
      "Egress policies need an explicit DNS rule (53 + 5353)" \
      "EgressFirewall: platform-owned control of external targets"
    ;;
esac
