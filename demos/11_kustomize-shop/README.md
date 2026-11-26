# Demo 11 – The shop with Kustomize

The real Kustomize layout of the ACME shop (`shop/deploy`): one base, five components,
two overlays – rendered, compared, applied and extended with an overlay of your own
(`my-overlay/`). Runs in its own project `demo-kustomize`, because the dev overlay closes
the namespace with NetworkPolicies.

```bash
cd demos/11_kustomize-shop
./demo-11-kustomize-shop.sh              # all steps
./demo-11-kustomize-shop.sh 2            # one step
./demo-11-kustomize-shop.sh cleanup
```

Needs `oc` (logged in); the cluster pulls the dev images of the shop
(`quay.io/tjungbau/shop-*-dev`). The dev overlay includes ServiceMonitors – the demo user
needs the `monitoring-edit` role (or cluster-admin).

| Step | What you see |
|---|---|
| 0 | the tree: `base/`, `components/`, `overlays/` and their kustomizations |
| 1 | `oc kustomize` of dev and prod – the objects, and that only images and components differ |
| 2 | the `postgres` component: new objects plus a patch for orders |
| 3 | `oc diff -k`, `oc apply -k` of dev, the Route – and a diff without differences |
| 4 | `my-overlay/`: 2 catalog replicas and `LOG_LEVEL=debug` – one Pod says `info`, the new one `debug` |

By hand, from the root of the repository:

```bash
oc kustomize shop/deploy/overlays/dev | less
oc diff -k shop/deploy/overlays/dev
oc apply -k shop/deploy/overlays/dev
oc apply -k demos/11_kustomize-shop/my-overlay
oc delete -k shop/deploy/overlays/dev
```
