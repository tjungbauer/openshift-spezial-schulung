# Demo 07 – The shop: many containers, one application

The complete shop – web, catalog, cart, orders and review – deployed with one command, so the
trainer can walk through it in the browser. The script waits during the walk-through and
deletes everything afterwards. Runs in its own project `demo-multi`.

```bash
cd demos/07_multi-container
./demo-07-multi-container.sh              # deploy, wait for the walk-through, clean up
./demo-07-multi-container.sh cleanup      # only delete the shop
```

Needs `oc` (logged in); the cluster pulls `quay.io/tjungbau/shop-*-dev:shop-test-dev`.

| Step | What happens |
|---|---|
| 1 | `oc apply -k .` – five Deployments, five Services, one Route; the script waits for every rollout |
| 2 | the script prints the URL of the shop and waits – walk through it in the browser, press ENTER when done |
| 3 | `oc delete -k .` – the shop is gone again |

Ctrl-C at any point asks whether to delete the shop (`DEMO_CLEANUP=y` deletes without asking).

In the browser: products, review stars, cart and an order – five services behind one page. The
footer shows which Pod answered. Optional, in a second terminal:

```bash
oc scale deployment/review --replicas=0     # the stars disappear, the shop keeps working
oc scale deployment/review --replicas=1
```

The files:

| File | Content |
|---|---|
| `kustomization.yaml` | the shop's `shop/deploy/base` with the dev images, label `app.kubernetes.io/part-of: demo-07` |

By hand, in the project `demo-multi`:

```bash
oc apply -k .
oc get deployment,service,route
ROUTE=$(oc get route web -o jsonpath='{.spec.host}')
echo https://$ROUTE
oc delete -k .
```
