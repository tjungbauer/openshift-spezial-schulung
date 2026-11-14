# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Lab 02 – shared tasks, checks and cleanup.
#  Sourced by lab-02-walkthrough.sh (interactive) and lab-02-solve.sh
#  (automatic), all three in lab-02/trainer/. Works on the lab files in
#  lab-02/ and uses the shared demo library from ../../demos/lib.
#
#  Namespace: LAB_NS / -n NAME (default: lab – created if missing; cleanup
#  removes the lab objects and PVCs, never the project).
#  Needs: oc, curl. The shop images are set in lab-02/shop/kustomization.yaml.
# ---------------------------------------------------------------------------

# this file lives in lab-02/trainer/ – the lab files are one level up
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT="${LAB_NS:-${DEMO_PROJECT:-lab}}"
# shellcheck source=../../../demos/lib/demo-lib.sh
source "${LAB_DIR}/../../demos/lib/demo-lib.sh"

SESSION="lab02-$$"     # shop_session cookie for the orders the script places
FAILS=0
PSQL='PGPASSWORD=$POSTGRESQL_PASSWORD psql -h localhost -U $POSTGRESQL_USER -d $POSTGRESQL_DATABASE'

# lab_init – call after parse_demo_args
lab_init() {
  LAB_NS="${DEMO_PROJECT}"
  require_cmd curl
  require_oc_login
  cd "${LAB_DIR}" || die "Cannot cd to ${LAB_DIR}"
}

route_url() {  # route_url NAME
  printf "https://%s" "$(oc -n "${LAB_NS}" get route "$1" -o jsonpath='{.spec.host}' 2>/dev/null)"
}

# place_order – one mug through the Route, like the UI does; prints the HTTP code
place_order() {
  curl -sk -o /dev/null -w '%{http_code}' -m 10 -X POST \
    -H 'Content-Type: application/json' --cookie "shop_session=${SESSION}" \
    -d '{"items":[{"product_id":"mug","quantity":1}]}' "$(route_url web)/api/orders/orders" || true
}

# order_count – rows in the orders table of PostgreSQL (empty if not reachable)
order_count() {
  oc -n "${LAB_NS}" exec postgres-0 -- bash -c "${PSQL} -tAc 'select count(*) from orders'" 2>/dev/null | tr -d '[:space:]' || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Tasks
# ═══════════════════════════════════════════════════════════════════════════

task1() {
  section "Task 1 · Deploy the shop"

  show_file shop/kustomization.yaml
  run "oc apply -k shop"
  run "oc get deployment,service,route"
  wait_until "all five Deployments ready" 300 \
    "oc rollout status deployment/web deployment/catalog deployment/cart deployment/orders deployment/review --timeout=5s" || true
  wait_until "the router serves the shop" 60 "curl -fsk $(route_url web)/health/ready" || true
  comment "The shop: $(route_url web)"
  comment "Place an order through the Route – like the UI does"
  info "  HTTP $(place_order)"

  discuss \
    "One Pod per component – five Deployments, five Services" \
    "" \
    "web is the only way in (Route) and calls the backends by" \
    "Service name: catalog, cart, orders, review." \
    "orders keeps the order in SQLite on an emptyDir –" \
    "gone when the orders Pod is replaced."
}

task2() {
  section "Task 2 · Switch off an optional service"

  run "oc scale deployment/review --replicas=0"
  wait_until "review gone" 60 "[[ -z \$(oc get pods -l app.kubernetes.io/name=review -o name) ]]" || true
  comment "Reload the shop now: no stars – browsing, cart and orders still work"
  pause
  run "oc scale deployment/review --replicas=1"
  run "oc rollout status deployment/review --timeout=120s"

  discuss \
    "Design for 'not there'" \
    "" \
    "review is optional: the UI shows no stars and keeps working." \
    "Every component that calls another one must cope with a" \
    "missing or slow dependency – degrade, do not crash."
}

task3() {
  section "Task 3 · The database as a StatefulSet"

  show_file postgres/statefulset.yaml
  pause
  run "oc apply -f postgres/"
  run "oc rollout status statefulset/postgres --timeout=180s"
  run "oc get statefulset,pod,pvc -l app.kubernetes.io/name=postgres"

  comment "The headless Service gives every replica its own DNS name"
  run "oc exec postgres-0 -- getent hosts postgres-0.postgres"

  discuss \
    "StatefulSet: identity + own storage" \
    "" \
    "Pod name postgres-0, not random – and it stays postgres-0." \
    "volumeClaimTemplates -> PVC data-postgres-0, kept on delete." \
    "Headless Service (clusterIP: None) -> postgres-0.postgres"
}

task4() {
  section "Task 4 · orders on PostgreSQL – with an init container"

  show_file orders-postgres.yaml
  pause
  run "oc patch deployment orders -p \"\$(cat orders-postgres.yaml)\""
  run "oc rollout status deployment/orders --timeout=180s"
  run "oc logs deployment/orders -c wait-for-db"

  comment "Place an order – it now lands in PostgreSQL"
  info "  HTTP $(place_order)"
  run "oc exec postgres-0 -- bash -c '${PSQL} -c \"select id, total_pence, pod from orders\"'"

  discuss \
    "Kubernetes has no depends_on – the Pod waits itself" \
    "" \
    "wait-for-db runs before orders and ends when pg_isready" \
    "succeeds: Init:0/1 -> Running. DATABASE_URL comes from the" \
    "Secret postgres; orders creates its table itself."
}

task5() {
  section "Task 5 · The backup CronJob"

  show_file backup/pvc.yaml
  run "oc apply -f backup/pvc.yaml"
  wait_until "PVC backups bound (needs RWX storage)" 120 \
    "[[ \$(oc get pvc backups -o jsonpath='{.status.phase}') == Bound ]]" || true
  run "oc get pvc backups"

  comment "Students fill in three TODOs in backup/cronjob.yaml – the finished file:"
  show_file reference/cronjob.yaml
  pause
  run "oc apply -f reference/cronjob.yaml"

  comment "Do not wait 5 minutes – start one Job from the CronJob now"
  oc delete job backup-now --ignore-not-found >/dev/null 2>&1 || true
  run "oc create job backup-now --from=cronjob/db-backup"
  run "oc wait --for=condition=complete job/backup-now --timeout=180s"
  run "oc logs job/backup-now"
  run "oc get cronjob,job"

  discuss \
    "CronJob -> Job -> Pod, runs to completion" \
    "" \
    "oc create job --from=cronjob/... starts one right now." \
    "concurrencyPolicy: Forbid – never two backups at once." \
    "pg_dump from the same image as the server; the dump is" \
    "written to a temp file and renamed when it is complete."
}

task6() {
  section "Task 6 · Show the backup – a second pod on the same volume"

  show_file backup/viewer.yaml
  pause
  run "oc apply -f backup/viewer.yaml"
  run "oc rollout status deployment/backup-viewer --timeout=120s"
  wait_until "the router serves backup-viewer" 60 "curl -fsk $(route_url backup-viewer)/" || true
  run "curl -sk $(route_url backup-viewer)/ | grep -o 'shop-[0-9TZ]*\\.dump' | sort -u"
  comment "In the browser: $(route_url backup-viewer)"

  discuss \
    "ReadWriteMany: two Pods, one volume, at the same time" \
    "" \
    "The CronJob writes, backup-viewer reads (mounted read-only)." \
    "With ReadWriteOnce both Pods would have to run on one node." \
    "The viewer is the Python runtime image + http.server."
}

bonus() {
  section "Bonus · identity and data survive"

  comment "Delete the database Pod – the StatefulSet re-creates postgres-0 with the same PVC"
  run "oc delete pod postgres-0"
  run "oc rollout status statefulset/postgres --timeout=180s"
  run "oc exec postgres-0 -- bash -c '${PSQL} -tAc \"select count(*) from orders\"'"

  comment "Replace the orders Pod – with PostgreSQL the orders stay"
  run "oc delete pod -l app.kubernetes.io/name=orders"
  run "oc rollout status deployment/orders --timeout=180s"

  discuss \
    "Same name, same volume, same data" \
    "" \
    "postgres-0 comes back as postgres-0 and mounts data-postgres-0." \
    "With SQLite on an emptyDir (task 1) the orders were lost."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Checks
# ═══════════════════════════════════════════════════════════════════════════

expect() {
  if [[ "$2" == "$3" ]]; then
    printf "  %sPASS%s  %-46s %s\n" "${C_OK}" "${C_RESET}" "$1" "$3"
  else
    printf "  %sFAIL%s  %-46s got %s, expected %s\n" "${C_ERR}" "${C_RESET}" "$1" "${3:-nothing}" "$2"
    FAILS=$((FAILS + 1))
  fi
}

check() {
  local d ready init url count
  FAILS=0
  section "Checks for namespace ${LAB_NS}"
  for d in web catalog cart orders review; do
    ready="$(oc -n "${LAB_NS}" get deployment "${d}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    expect "Deployment ${d} ready" "yes" "$([[ "${ready:-0}" -ge 1 ]] && echo yes || echo no)"
  done
  expect "shop answers through the Route" "200" \
    "$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "$(route_url web)/" 2>/dev/null || true)"
  expect "StatefulSet postgres ready" "1" \
    "$(oc -n "${LAB_NS}" get statefulset postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  expect "PVC data-postgres-0 bound" "Bound" \
    "$(oc -n "${LAB_NS}" get pvc data-postgres-0 -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  init="$(oc -n "${LAB_NS}" get deployment orders -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null || true)"
  expect "orders has the init container wait-for-db" "wait-for-db" "${init}"
  url="$(oc -n "${LAB_NS}" get deployment orders \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DATABASE_URL")].value}' 2>/dev/null || true)"
  expect "orders uses PostgreSQL (DATABASE_URL)" "yes" "$([[ "${url}" == postgresql://* ]] && echo yes || echo no)"
  count="$(order_count)"
  expect "orders table in PostgreSQL has rows" "yes" "$([[ "${count:-0}" =~ ^[0-9]+$ && "${count}" -ge 1 ]] && echo yes || echo "${count:-none}")"
  expect "PVC backups bound, ReadWriteMany" "Bound ReadWriteMany" \
    "$(oc -n "${LAB_NS}" get pvc backups -o jsonpath='{.status.phase} {.spec.accessModes[0]}' 2>/dev/null || true)"
  expect "CronJob db-backup every 5 minutes" "*/5 * * * *" \
    "$(oc -n "${LAB_NS}" get cronjob db-backup -o jsonpath='{.spec.schedule}' 2>/dev/null || true)"
  expect "backup-viewer lists a dump" "yes" \
    "$(curl -sk -m 5 "$(route_url backup-viewer)/" 2>/dev/null | grep -q 'shop-.*\.dump' && echo yes || echo no)"

  printf "\n"
  if [[ ${FAILS} -eq 0 ]]; then success "All checks passed"; else warn "${FAILS} check(s) failed"; fi
  return "${FAILS}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  oc -n "${LAB_NS}" delete -f backup/viewer.yaml --ignore-not-found >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" delete cronjob/db-backup job/backup-now --ignore-not-found >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" delete -f postgres/ --ignore-not-found >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" delete -k shop --ignore-not-found >/dev/null 2>&1 || true
  oc -n "${LAB_NS}" delete pvc backups data-postgres-0 --ignore-not-found >/dev/null 2>&1 || true
  info "deleted the shop, PostgreSQL, the backup objects and both PVCs in ${LAB_NS} (project kept)"
}
