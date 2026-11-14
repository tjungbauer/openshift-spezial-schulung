# Demo 10 – The shop as a Helm chart

The ACME shop installed, changed, extended and rolled back with its Helm chart
(`shop/deploy/helm/shop`). Runs in its own project `demo-shop`, because the chart
closes the namespace with NetworkPolicies.

```bash
cd demos/10_helm-shop
./demo-10-helm-shop.sh              # all steps
./demo-10-helm-shop.sh 3            # one step
./demo-10-helm-shop.sh cleanup
```

Needs `oc` (logged in), `helm` and `curl`; the cluster pulls the shop images
(`quay.io/tjungbau/shop-*`) and, from step 4, `registry.redhat.io/rhel9/postgresql-16`.

| Step | What you see |
|---|---|
| 0 | the chart: `Chart.yaml`, `values-dev.yaml`, `values-prod.yaml` |
| 1 | `helm lint`, `helm template` – the objects, the checksum annotation, `.Capabilities` |
| 2 | `helm upgrade --install … --wait` with the dev values, NOTES, the Route |
| 3 | `--set logLevel=debug` – only catalog and orders get new Pods (checksum) |
| 4 | PostgreSQL on top of dev: the chart refuses (`fail`); prod values: StatefulSet, migration hook, backups |
| 5 | `helm test`, `helm rollback` – the PVC `data-postgres-0` survives |

By hand, from `revoked/shop`:

```bash
export CHART=deploy/helm/shop
helm upgrade --install shop $CHART -f $CHART/values-dev.yaml --wait --timeout 5m
helm upgrade shop $CHART -f $CHART/values-dev.yaml --set logLevel=debug --wait
helm upgrade shop $CHART -f $CHART/values-prod.yaml --wait --timeout 5m
helm test shop
helm rollback shop 2 --wait
helm uninstall shop
oc delete pvc data-postgres-0
```
