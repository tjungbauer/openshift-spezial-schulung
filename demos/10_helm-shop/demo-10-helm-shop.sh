#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 10 – The shop as a Helm chart
#  Run:     ./demo-10-helm-shop.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in, helm, curl
#  The demo runs in the project "demo-shop" (or NAME), created if missing –
#  its own project, because the chart closes the namespace with NetworkPolicies.
#  Chart: shop/deploy/helm/shop
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-shop}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-5); default: all steps
  cleanup                uninstall the release and delete its leftovers"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-5]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

# shown as $CHART, $DEV and $PROD in the commands
CHART="$(cd "${SCRIPT_DIR}/../../shop/deploy/helm/shop" 2>/dev/null && pwd)" \
  || die "Chart not found: shop/deploy/helm/shop"
export CHART DEV="${CHART}/values-dev.yaml" PROD="${CHART}/values-prod.yaml"
RELEASE="shop"

route_url() {
  printf "https://%s" "$(oc get route web -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  local ns="${DEMO_PROJECT}" job
  info "uninstalling release ${RELEASE} ..."
  helm -n "${ns}" uninstall "${RELEASE}" --wait --timeout 2m >/dev/null 2>&1 || true

  # Helm does not remove everything: hook objects (test pod, a failed migration
  # Job), the Jobs the CronJob created, and leftovers of a failed uninstall.
  # Order matters: first whatever mounts a PVC, then the PVCs.
  info "deleting StatefulSet, CronJob and Deployments ..."
  oc -n "${ns}" delete statefulset,cronjob,deployment -l app.kubernetes.io/part-of=shop \
    --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  info "deleting Jobs and Pods ..."
  for job in $(oc -n "${ns}" get jobs -o name 2>/dev/null | grep -E '/(db-backup|orders-migrate)' || true); do
    oc -n "${ns}" delete "${job}" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  done
  oc -n "${ns}" delete pod -l app.kubernetes.io/part-of=shop \
    --ignore-not-found --grace-period=1 --timeout=60s >/dev/null 2>&1 || true
  oc -n "${ns}" wait --for=delete pod/postgres-0 --timeout=120s >/dev/null 2>&1 || true

  # data-postgres-0 was created by the StatefulSet, not by Helm – uninstall keeps it.
  # --wait=false: never hang here; a PVC still in use finishes deleting on its own.
  info "deleting PVCs ..."
  oc -n "${ns}" delete pvc data-postgres-0 backups orders-data \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if oc -n "${ns}" get pvc data-postgres-0 >/dev/null 2>&1; then
    warn "PVC data-postgres-0 is still terminating – something still uses it: oc get pods -n ${ns}"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · The chart – one chart, two value files"

  run "find \$CHART -type f | sed \"s#\$CHART/##\" | sort"
  show_file "${CHART}/Chart.yaml"
  comment "dev and prod differ only in a few values"
  show_file "${DEV}"
  show_file "${PROD}"
  pause

  discuss \
    "Same chart, different shop" \
    "" \
    "  values.yaml       defaults - SQLite on an emptyDir" \
    "  values-dev.yaml   dev images, SQLite on a PVC" \
    "  values-prod.yaml  release images, PostgreSQL, backups" \
    "" \
    "The Kustomize overlays do the same with components -" \
    "the rendered objects are identical."
}

step1() {
  section "1 · Render before you install"

  run "helm lint \$CHART -f \$DEV"
  run "helm template shop \$CHART -f \$DEV | grep '^kind:' | sort | uniq -c"

  discuss \
    "helm template renders locally - nothing reaches the cluster" \
    "" \
    "No ServiceMonitor in the list? It is only rendered when the cluster" \
    "has the API (.Capabilities) - helm template does not ask it." \
    "  helm template ... --api-versions monitoring.coreos.com/v1"
}

step2() {
  section "2 · Install the dev variant"
  helm uninstall "${RELEASE}" --wait >/dev/null 2>&1 || true

  run "helm upgrade --install shop \$CHART -f \$DEV --wait --timeout 5m"
  run "helm list"
  run "oc get deployment,service,route,pvc -l app.kubernetes.io/instance=shop"
  run "echo \$(oc get route web -o jsonpath='https://{.spec.host}')"

  discuss \
    "One command, the whole shop - and NOTES.txt tells you what next" \
    "" \
    "--wait: success only when every Pod is Ready (readiness probes)." \
    "Release shop, revision 1 - stored as a Secret in the namespace." \
    "Open the shop in the browser, put something in the cart, order."
}

step3() {
  section "3 · Change one value – who restarts?"

  run "oc get pods -l app.kubernetes.io/part-of=shop"
  run "helm upgrade shop \$CHART -f \$DEV --set logLevel=debug --wait"
  comment "Only catalog and orders have a new Pod – their ConfigMap changed"
  run "oc get pods -l app.kubernetes.io/part-of=shop"
  run "helm history shop"

  discuss \
    "checksum/config: sha256 of the rendered ConfigMap" \
    "" \
    "logLevel ends up in the ConfigMaps of catalog and orders." \
    "New ConfigMap -> new checksum -> new Pod template -> rolling update." \
    "web, cart and review are untouched." \
    "" \
    "Without the checksum: the ConfigMap changes, the Pods do not."
}

step4() {
  section "4 · PostgreSQL – and a chart that says no"

  comment "What runs now: dev values (orders on SQLite with the PVC orders-data)"
  run "grep -A2 '^orders:' \$DEV"
  comment "The chart checks its values before it renders anything – a named template in _helpers.tpl"
  run "sed -n '/define \"shop.validate\"/,/^{{- end }}/p' \$CHART/templates/_helpers.tpl"
  comment "deployment-web.yaml calls it once – that is why the error names that file"
  run "head -2 \$CHART/templates/deployment-web.yaml"

  comment "Now ask for PostgreSQL on top of the dev values – orders would get BOTH stores"
  run "helm upgrade shop \$CHART -f \$DEV --set postgresql.enabled=true"
  comment "Nothing changed: no new revision, the Pods keep running"
  run "helm history shop"

  discuss \
    "Why does the chart say no?" \
    "" \
    "orders.persistence + postgresql = two stores for one service:" \
    "  - the PVC orders-data is created and mounted for SQLite" \
    "  - DATABASE_URL is set too - orders uses PostgreSQL" \
    "  -> a PVC that is bound, paid for and never used" \
    "" \
    "fail stops the RENDERING: nothing is sent to the cluster," \
    "no new revision. Same rule: backup.enabled needs postgresql." \
    "Kustomize only has this as a comment - Helm enforces it."

  comment "The prod values switch the PVC off and PostgreSQL on: StatefulSet, migration hook, backups"
  run "helm upgrade shop \$CHART -f \$PROD --wait --timeout 5m"
  run "oc get statefulset,pvc,cronjob"
  run "helm get hooks shop | grep -E '^# Source|helm.sh/hook'"

  discuss \
    "The migration Job is a hook, not a normal object" \
    "" \
    "orders-migrate runs post-install / post-upgrade:" \
    "  - after the objects are created (the database exists)" \
    "  - before-hook-creation deletes the old Job first" \
    "  - hook-succeeded removes it when it worked" \
    "Hooks are not part of the release manifest: helm get hooks." \
    "" \
    "orders-data is gone - Helm created it, Helm deleted it." \
    "data-postgres-0 is new - the StatefulSet created it."
}

step5() {
  section "5 · Test, roll back – and what survives"

  run "helm test shop"
  run "helm history shop"
  run "helm rollback shop 2 --wait"
  run "oc get statefulset,pvc"
  run "helm history shop"

  discuss \
    "Rollback = a new revision with the old values" \
    "" \
    "Back to SQLite: the StatefulSet is gone - its PVC data-postgres-0" \
    "is still there. Helm did not create it, the StatefulSet did." \
    "" \
    "Rollback does not touch data - the orders in PostgreSQL stay" \
    "in that PVC until someone deletes it."
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
require_cmd helm curl
require_oc_login
printf "%sChart:  %s %s\n" "${C_BOLD}" "${C_RESET}" "${CHART}"

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [0-5])
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    on_exit_cleanup cleanup "Uninstall the shop and delete its PVC? [y/N]"

    title "Demo 10 – The shop as a Helm chart" "render · install · upgrade · hooks · test · rollback"
    for i in 0 1 2 3 4 5; do "step${i}"; done

    takeaways \
      "One chart, value files per environment" \
      "helm template and helm lint before every install" \
      "A checksum annotation rolls exactly the Pods whose config changed" \
      "fail and required stop impossible values early" \
      "Hooks and tests run at defined points of the release" \
      "Rollback restores objects, not data – PVCs stay"
    ;;
esac
