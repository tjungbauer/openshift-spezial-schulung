#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 11 – The shop with Kustomize
#  Run:     ./demo-11-kustomize-shop.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in
#  The demo runs in the project "demo-kustomize" (or NAME), created if missing –
#  its own project, because the dev overlay closes the namespace with
#  NetworkPolicies. Uses shop/deploy and the overlay in my-overlay/.
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-kustomize}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-4); default: all steps
  cleanup                delete what the demo created"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-4]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

# shown as $DEPLOY in the commands
DEPLOY="$(cd "${SCRIPT_DIR}/../../shop/deploy" 2>/dev/null && pwd)" \
  || die "Not found: shop/deploy"
export DEPLOY
cd "${SCRIPT_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  local ns="${DEMO_PROJECT}"
  info "deleting the dev overlay of the shop ..."
  # everything the overlay renders; PVC orders-data last (--wait=false: never hang)
  oc -n "${ns}" delete -k "${DEPLOY}/overlays/dev" --ignore-not-found \
    --timeout=120s >/dev/null 2>&1 || true
  oc -n "${ns}" delete configmap catalog --ignore-not-found >/dev/null 2>&1 || true
  oc -n "${ns}" delete pvc orders-data --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · The layout – base, components, overlays"

  run "find \$DEPLOY/base \$DEPLOY/components \$DEPLOY/overlays -name kustomization.yaml | sed \"s#\$DEPLOY/##\" | sort"
  show_file "${DEPLOY}/base/kustomization.yaml"
  show_file "${DEPLOY}/overlays/dev/kustomization.yaml"
  pause

  discuss \
    "Who owns what is visible in the tree" \
    "" \
    "  base/        one folder per service - shared by every environment" \
    "  components/  features: networkpolicies, monitoring, postgres, backup" \
    "  overlays/    dev and prod pick images and components, no copied YAML" \
    "" \
    "The base has no namespace: the overlay or oc -n decides."
}

step1() {
  section "1 · Render and compare – dev vs prod"

  run "oc kustomize \$DEPLOY/overlays/dev | grep '^kind:' | sort | uniq -c"
  run "oc kustomize \$DEPLOY/overlays/prod | grep '^kind:' | sort | uniq -c"
  comment "Only the images and the components differ (< dev, > prod; exit code 1 = there are differences)"
  run "diff <(oc kustomize \$DEPLOY/overlays/dev) <(oc kustomize \$DEPLOY/overlays/prod) | awk '/^[<>] .*image:/ {print \$1, \$NF}' | sort -u"

  discuss \
    "oc kustomize renders locally - no cluster, no surprises" \
    "" \
    "dev: SQLite on a PVC (persistent-orders)" \
    "prod: PostgreSQL StatefulSet, migration Job, backup CronJob" \
    "Same base - the components make the difference."
}

step2() {
  section "2 · A component from the inside – postgres"

  show_file "${DEPLOY}/components/postgres/kustomization.yaml"
  comment "The component adds objects AND patches the orders Deployment of the base"
  show_file "${DEPLOY}/components/postgres/orders-database.yaml"
  pause
  run "oc kustomize \$DEPLOY/overlays/prod | grep -B1 -A1 'name: DATABASE_URL'"

  discuss \
    "kind: Component - resources and patches, used by any overlay" \
    "" \
    "postgres brings Secret, headless Service, StatefulSet, Job, policy" \
    "and switches orders to PostgreSQL with a strategic-merge patch." \
    "Without the component: orders keeps SQLite - nothing else changes."
}

step3() {
  section "3 · Preview, then apply the dev overlay"

  comment "What would change in the cluster? (exit code 1 = there are differences)"
  run "oc diff -k \$DEPLOY/overlays/dev | head -40"
  run "oc apply -k \$DEPLOY/overlays/dev"
  run "oc get deployment,service,route,pvc,networkpolicy"
  run "echo \$(oc get route web -o jsonpath='https://{.spec.host}')"
  comment "Once more – now the cluster matches Git: no output"
  run "oc diff -k \$DEPLOY/overlays/dev"
}

step4() {
  section "4 · Your own overlay – on top of dev"

  show_file my-overlay/kustomization.yaml
  run "oc kustomize my-overlay | grep -B2 -A6 '^kind: ConfigMap' | head -12"
  run "oc apply -k my-overlay"
  run "oc rollout status deployment/catalog --timeout=120s"
  comment "Which LOG_LEVEL does each catalog Pod have?"
  run "for p in \$(oc get pods -l app.kubernetes.io/name=catalog -o name); do echo \"\$p  LOG_LEVEL=\$(oc exec \$p -c catalog -- python3.12 -c 'import os; print(os.getenv(\"LOG_LEVEL\"))')\"; done"

  discuss \
    "One Pod says info, the new one says debug" \
    "" \
    "The ConfigMap catalog has no generator hash: its content changed," \
    "its name did not - so the Pod template did not change either." \
    "Only the second replica, started now, reads the new value." \
    "" \
    "A configMapGenerator (name + hash) makes every change roll out."
}
# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login
printf "%sShop:   %s %s\n" "${C_BOLD}" "${C_RESET}" "${DEPLOY}"

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [0-4])
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    on_exit_cleanup cleanup "Delete the shop from ${DEMO_PROJECT}? [y/N]"

    title "Demo 11 – The shop with Kustomize" "base · components · overlays · diff · apply"
    for i in 0 1 2 3 4; do "step${i}"; done

    takeaways \
      "Base = shared, components = features, overlays = environments" \
      "oc kustomize renders locally – compare overlays before deploying" \
      "oc diff -k before every apply" \
      "Your own overlay can extend any kustomization – without copying it" \
      "Only a generator hash makes a config change roll out by itself"
    ;;
esac
