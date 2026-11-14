# Deploy the ACME shop – dev and prod, with the full demo

Every command below was run against OpenShift 5.0.1 (Kubernetes 1.36) on
2026-11-12. Change the variables in step 0, then copy the blocks one by one.

| Project | Overlay | Images | Components |
|---|---|---|---|
All five services – web, catalog, cart, orders and the optional **review** – in both projects.

| `$DEV_NS` (shop-dev) | `deploy/overlays/dev` | `$REGISTRY/shop-<service>-dev:$DEV_TAG` | networkpolicies, monitoring, **persistent-orders** (SQLite on a PVC) |
| `$PROD_NS` (shop) | `deploy/overlays/prod` | `$REGISTRY/shop-<service>:$PROD_TAG` | networkpolicies, monitoring, **postgres** (PostgreSQL StatefulSet), **backup** (pg_dump CronJob + backup-viewer) |

## 0 · Variables – change these

```bash
export SHOP=/Users/tjungbau/Downloads/ocp-enablement-main/revoked/shop
export KUBECONFIG=/Users/tjungbau/openshift-aws/aws/auth/kubeconfig

export REGISTRY=quay.io/tjungbau        # images: $REGISTRY/shop-<service>[-dev]:<tag>
export DEV_NS=shop-dev
export DEV_TAG=shop-test-dev
export PROD_NS=shop
export PROD_TAG=shop-test

# macOS only: rootless podman cannot run arbitrary UIDs – use the rootful podman machine
export PODMAN="podman --connection podman-machine-default-root"

cd "$SHOP"
```

The repositories `$REGISTRY/shop-{catalog,cart,orders,review,web}` and `…-dev` must
exist and be public (or the projects need a pull secret).

## 1 · Access – once

```bash
oc whoami                       # cluster login works?
podman login quay.io            # the host part of $REGISTRY
```

## 2 · Cluster prerequisite – once per cluster, cluster-admin

User workload monitoring, so the ServiceMonitors of the shop are scraped:

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  || oc apply -f deploy/cluster/user-workload-monitoring.yaml
oc get pods -n openshift-user-workload-monitoring        # prometheus-user-workload-* Running
```

If `cluster-monitoring-config` already exists, add `enableUserWorkload: true`
to its `config.yaml` instead. The other prerequisites are standard on OpenShift:
a default StorageClass (PVC, PostgreSQL) and `registry.redhat.io` in the global
pull secret (PostgreSQL image).

## 3 · Test and build

```bash
make test                        # unit tests
make validate                    # kustomize build + kubeconform, both overlays and all components
make build                       # 4 images, linux/amd64
make check-images                # optional: each image as UID 1000680000:0 answers /health/ready
```

## 4 · Push – checks the repositories first, verifies every image afterwards

```bash
make push REGISTRY=$REGISTRY IMAGE_SUFFIX=-dev IMAGE_TAG=$DEV_TAG
make push REGISTRY=$REGISTRY IMAGE_TAG=$PROD_TAG
```

## 5 · Deploy – creates the projects if needed, waits for the rollouts

`SET_IMAGES=true` points the overlay at `$REGISTRY/…:<tag>` first
(`kustomize edit set image` – rewrites the overlay file). `RESTART=true` restarts
every Deployment afterwards – needed when you pushed new images under the **same**
tag (the Deployments use `imagePullPolicy: Always`, but an unchanged Deployment
does not roll out by itself).

```bash
make deploy OVERLAY=dev  NAMESPACE=$DEV_NS  SET_IMAGES=true RESTART=true REGISTRY=$REGISTRY IMAGE_SUFFIX=-dev IMAGE_TAG=$DEV_TAG
make deploy OVERLAY=prod NAMESPACE=$PROD_NS SET_IMAGES=true RESTART=true REGISTRY=$REGISTRY IMAGE_TAG=$PROD_TAG

# prod: PostgreSQL, the migration Job and the backup viewer
oc rollout status statefulset/postgres -n $PROD_NS --timeout=300s
oc wait --for=condition=complete job/orders-migrate -n $PROD_NS --timeout=300s
oc rollout status deploy/backup-viewer -n $PROD_NS --timeout=300s

export DEV_URL=https://$(oc get route web -n $DEV_NS  -o jsonpath='{.spec.host}')
export PROD_URL=https://$(oc get route web -n $PROD_NS -o jsonpath='{.spec.host}')
echo "dev:  $DEV_URL"; echo "prod: $PROD_URL"
```

`oc apply` reports `secret/postgres configured` and `statefulset.apps/postgres configured`
on every run – a harmless quirk of client-side apply (`stringData` is not stored,
`volumeClaimTemplates` get server defaults); nothing changes on the server.

Without make, the same with plain oc (images as they are in the overlay files):

```bash
oc new-project $DEV_NS --skip-config-write
oc apply -n $DEV_NS -k deploy/overlays/dev
oc new-project $PROD_NS --skip-config-write
oc apply -n $PROD_NS -k deploy/overlays/prod
```

## 6 · Smoke test through the Routes

```bash
make smoke ROUTE_URL=$DEV_URL
make smoke ROUTE_URL=$PROD_URL
oc get pods,pvc,networkpolicy,servicemonitor -n $DEV_NS
oc get pods,pvc,networkpolicy,servicemonitor,job -n $PROD_NS
```

Open both URLs in the browser: the footer shows version, revision and pod of
every service, the status panel shows each backend green.

---

## 7 · The demo

### review is optional – stop it, the shop keeps working

Open `$PROD_URL` in the browser next to the terminal:

```bash
oc scale deploy/review -n $PROD_NS --replicas=0
# within ~10 s: the stars disappear, the status panel shows "review: unreachable" –
# products, cart and checkout keep working
curl -sk -o /dev/null -w 'products: %{http_code}\n' $PROD_URL/api/catalog/products   # 200
curl -sk -o /dev/null -w 'reviews:  %{http_code}\n' $PROD_URL/api/review/reviews     # 502
oc scale deploy/review -n $PROD_NS --replicas=1
oc rollout status deploy/review -n $PROD_NS        # the stars come back within ~10 s
```

Why it works: the UI loads the products first and the stars separately; a failed
`/api/review/…` call only removes the stars. The Service `review` stays when the
pods are gone, so web (nginx) keeps running and answers 502 for review.

### NetworkPolicies – only the paths the shop needs

```bash
oc get networkpolicy -n $DEV_NS
# the Route works (router -> web is allowed):
curl -sk -o /dev/null -w 'route: %{http_code}\n' $DEV_URL/
# a pod without permission inside the project: blocked (000 = timeout)
oc run np-test -n $DEV_NS --rm -i -q --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --command -- \
  curl -s -m 4 -o /dev/null -w 'catalog: %{http_code}\n' http://catalog:8080/info
# from the other project: blocked as well
oc run np-test -n $DEV_NS --rm -i -q --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --command -- \
  curl -s -m 4 -o /dev/null -w "prod catalog: %{http_code}\n" http://catalog.$PROD_NS.svc:8080/info
```

(`oc run` prints a PodSecurity warning – the test pod has no securityContext; see demo 01.)

### PVC – orders survive a restart (dev)

```bash
curl -sk -b shop_session=demo -X POST $DEV_URL/api/orders/orders \
  -H 'Content-Type: application/json' -d '{"items":[{"product_id":"plant","quantity":1}]}'
oc delete pod -n $DEV_NS -l app.kubernetes.io/name=orders
oc rollout status deploy/orders -n $DEV_NS
curl -sk -b shop_session=demo $DEV_URL/api/orders/orders     # the order is still there, "persistent":true
```

In the UI: the Orders drawer no longer warns that orders are lost on restart.

### PostgreSQL – StatefulSet, headless Service, migration Job (prod)

```bash
oc get statefulset,pod,pvc,svc,job -n $PROD_NS -l 'app.kubernetes.io/name in (postgres,orders-migrate)'
oc logs job/orders-migrate -n $PROD_NS
curl -sk -b shop_session=demo -X POST $PROD_URL/api/orders/orders \
  -H 'Content-Type: application/json' -d '{"items":[{"product_id":"teddy","quantity":2}]}'
curl -sk -b shop_session=demo $PROD_URL/api/orders/orders    # "storage":"postgresql","persistent":true
oc exec -n $PROD_NS postgres-0 -- psql -U shop -d shop -c 'select id, total_pence, pod from orders'
# restart database and orders – the orders stay
oc delete pod -n $PROD_NS postgres-0
oc delete pod -n $PROD_NS -l app.kubernetes.io/name=orders
oc rollout status statefulset/postgres -n $PROD_NS && oc rollout status deploy/orders -n $PROD_NS
oc exec -n $PROD_NS postgres-0 -- psql -U shop -d shop -tAc 'select count(*) from orders'
```

### Backups – CronJob, PVC shared by two pods (prod)

```bash
oc get cronjob,pvc -n $PROD_NS -l app.kubernetes.io/name=db-backup
oc create job db-backup-now --from=cronjob/db-backup -n $PROD_NS     # don't wait 5 minutes
oc wait --for=condition=complete job/db-backup-now -n $PROD_NS --timeout=300s
oc logs job/db-backup-now -n $PROD_NS
# the dumps, from the terminal (backup-viewer mounts the PVC read-only; no Route on purpose):
oc rsh -n $PROD_NS deploy/backup-viewer sh -c 'cd /backups && ls -l shop-*.dump && du -sh .'
oc rsh -n $PROD_NS deploy/backup-viewer          # or interactively: a shell in the viewer pod
# writer and reader share a ReadWriteOnce volume – so they run on the same node:
oc get pods -n $PROD_NS -l 'app.kubernetes.io/name in (backup-viewer,db-backup)' -o wide
# is the newest dump usable? stream it into pg_restore (in the postgres pod)
F=$(oc exec -n $PROD_NS deploy/backup-viewer -- sh -c 'cd /backups && ls -1t shop-*.dump | head -1')
oc exec -n $PROD_NS deploy/backup-viewer -- sh -c "cd /backups && cat $F" \
  | oc exec -i -n $PROD_NS postgres-0 -- pg_restore --list | grep TABLE
oc delete job db-backup-now -n $PROD_NS
```

Discussion point: ReadWriteOnce means one **node**, not one pod. With file storage
(ODF CephFS, NFS, EFS) the PVC could be ReadWriteMany and the affinity could go.

### Monitoring – metrics of both projects

Console: **Observe → Metrics** (in the project, or as admin across projects), e.g.

```
sum by (namespace, result) (shop_orders_total)
sum by (namespace, service) (rate(shop_http_requests_total[5m]))
histogram_quantile(0.95, sum by (le, service) (rate(shop_http_request_duration_seconds_bucket[5m])))
```

`shop_orders_total` appears after the first order since the orders pod started.
From the command line (cluster-admin):

```bash
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=up%7Bnamespace%3D~%22shop.*%22%7D'   # 6 targets, all "1"
```

### Load balancing and the canary look

```bash
oc scale deploy/catalog -n $DEV_NS --replicas=3
oc rollout status deploy/catalog -n $DEV_NS
for i in $(seq 10); do curl -sk $DEV_URL/api/catalog/info; echo; done   # different pods answer
oc set env deploy/catalog -n $DEV_NS APP_VERSION=2.0.0                    # UI turns purple, "new" badges
# back:
oc set env deploy/catalog -n $DEV_NS APP_VERSION-
oc scale deploy/catalog -n $DEV_NS --replicas=1
```

Watch the footer of the UI during the rollout: the catalog pod and version change live.

### Probes – a pod that is not ready gets no traffic

Through a rollout: the new pod never gets ready, so the old one keeps serving –
the rollout stalls instead of breaking the shop.

```bash
oc set env deploy/catalog -n $DEV_NS FAULT_FAIL_READY=true
oc get pods -n $DEV_NS -l app.kubernetes.io/name=catalog -w   # new pod 0/1, old pod 1/1 – Ctrl-C
oc set env deploy/catalog -n $DEV_NS FAULT_FAIL_READY-
```

In the running pod (UI shows catalog **red**): switch the fault on at runtime.

```bash
oc set env deploy/catalog -n $DEV_NS ADMIN_TOKEN=s3cret && oc rollout status deploy/catalog -n $DEV_NS
oc port-forward deploy/catalog -n $DEV_NS 8081:8080 &
curl -X POST localhost:8081/admin/fault -H 'Authorization: Bearer s3cret' \
     -H 'Content-Type: application/json' -d '{"fail_ready": true}'     # catalog leaves the Service -> red
curl -X POST localhost:8081/admin/fault -H 'Authorization: Bearer s3cret' \
     -H 'Content-Type: application/json' -d '{"fail_ready": false}'    # back to green
kill %1
oc set env deploy/catalog -n $DEV_NS ADMIN_TOKEN-
```

More knobs (delay, error rate, slow start): see "Fault injection" in README.md.

---

## 8 · Clean up

```bash
oc delete project $DEV_NS $PROD_NS
# cluster-admin, only if nothing else uses user workload monitoring:
oc delete configmap cluster-monitoring-config -n openshift-monitoring
```
