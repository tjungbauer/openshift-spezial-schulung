# Demo 19 – Canary and fault injection

The shop of demo 18 – ambient mode, waypoint, `shopper` – with **catalog in two versions**. A
DestinationRule names the versions, a VirtualService splits the traffic 90 / 10, then injects
errors and delays. The waypoint applies the rules; the shop does not change. Runs in its own
project `demo-traffic`. About 6 minutes (each step collects 30 s of traffic).

```bash
cd demos/19_mesh-traffic
../18_mesh-onboarding/admin/namespace-in-mesh.sh demo-traffic   # cluster-admin, once
./demo-19-mesh-traffic.sh              # all steps
./demo-19-mesh-traffic.sh 2            # one step (creates what it needs)
./demo-19-mesh-traffic.sh cleanup
```

| Step | What you see |
|---|---|
| 0 | `catalog` (v1) and `catalog-v2` behind one Service – the catalog logs count about half of the calls each; the Kiali link (versioned app graph) |
| 1 | `rules/destinationrule.yaml` + `rules/canary-90-10.yaml` – about 90 % of the calls in v1's log, 10 % in v2's |
| 2 | `rules/fault-abort.yaml` – about half of the shopper's catalog calls get `503`; reload the shop in the browser |
| 3 | `rules/fault-delay.yaml` – half of the catalog calls take 2 s more: average and maximum time of the shopper's catalog calls |
| 4 | `oc delete -f rules/` – round robin again, only `200` |

Needs: everything demo 18 needs (ambient mode, Gateway API, user workload monitoring) and the
namespace in the mesh scope. The demo builds on `../18_mesh-onboarding/waypoint` – it deploys the
same shop, it does not need demo 18 to run first.

The files:

| File | Content |
|---|---|
| `kustomization.yaml` | `../18_mesh-onboarding/waypoint`, `catalog-v2.yaml`, and a patch: the existing catalog gets `version: v1` (selector and Pod template) |
| `catalog-v2.yaml` | Deployment `catalog-v2` (same image, `version: v2`, ambient label) and the Services `catalog-v1` / `catalog-v2` for the Gateway API variant |
| `rules/destinationrule.yaml` | subsets `v1` / `v2` by the label `version` |
| `rules/canary-90-10.yaml` | VirtualService `catalog`: weights 90 / 10 |
| `rules/fault-abort.yaml` | VirtualService `catalog`: 50 % abort with 503 |
| `rules/fault-delay.yaml` | VirtualService `catalog`: 50 % delay of 2 s |
| `rules/canary-httproute.yaml` | the canary with the Gateway API: HTTPRoute on the Service `catalog`, weights to `catalog-v1` / `catalog-v2` |

All rules use the name `catalog` – applying one replaces the previous one. In ambient mode the
VirtualService works only for Services that use a waypoint (`istio.io/use-waypoint`, set in demo
18). For waypoints the Gateway API is the recommended API; if the VirtualService has no effect on
your version, use `rules/canary-httproute.yaml` instead of steps 1's two files.

How the demo counts: every catalog Pod logs one JSON line per request – `grep -c '"path":
"/products'` per Deployment shows who answered. The shopper logs `<time> <method> <path> <status>
<seconds>` per call.
