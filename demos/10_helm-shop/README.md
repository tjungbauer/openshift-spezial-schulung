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
(`quay.io/tjungbau/shop-*`).

| Step | What you see |
|---|---|
| 0 | the chart: `Chart.yaml`, `values-dev.yaml`, `values-prod.yaml` |
| 1 | `helm lint`, `helm template` – the objects, the checksum annotation, `.Capabilities` |
| 2 | `helm upgrade --install … --wait` with the dev values, NOTES, the Route |
| 3 | `--set logLevel=debug` – only catalog and orders get new Pods (checksum) |
| 4 | `helm test`, `helm rollback shop 1` – a new revision with the old values; PVCs stay |

By hand, from `shop/` in the repository:

```bash
export CHART=deploy/helm/shop
helm upgrade --install shop $CHART -f $CHART/values-dev.yaml --wait --timeout 5m
helm upgrade shop $CHART -f $CHART/values-dev.yaml --set logLevel=debug --wait
helm test shop
helm rollback shop 1 --wait
helm uninstall shop
oc delete pvc -l app.kubernetes.io/instance=shop
```
