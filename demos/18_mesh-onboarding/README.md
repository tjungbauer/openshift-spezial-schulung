# Demo 18 – The shop joins the mesh (ambient mode)

Who does what when an application joins OpenShift Service Mesh 3 in **ambient mode**. The
**cluster-admin** has installed the mesh (profile ambient, ztunnel on every node) and puts the
namespace into its scope. The **application team** brings the real shop – the dev overlay with
all five services, NetworkPolicies and ServiceMonitors – adds one label to every Pod template,
opens the mesh port in its NetworkPolicies and, for L7, adds a waypoint. No sidecar: the Pods
stay `1/1`. A `shopper` Pod uses every service of the shop through web, so Kiali shows the whole
call graph. Runs in its own project `demo-mesh`. About 7 minutes.

```bash
cd demos/18_mesh-onboarding
./admin/namespace-in-mesh.sh demo-mesh                # cluster-admin, once
./demo-18-mesh-onboarding.sh                          # all steps
./demo-18-mesh-onboarding.sh 2                        # one step (creates what it needs)
./demo-18-mesh-onboarding.sh cleanup
```

| Step | Who | What you see |
|---|---|---|
| 0 | cluster-admin | `oc get istio,istiocni,ztunnel`, profile `ambient`, the ztunnel DaemonSet, the label `istio-discovery=enabled` on the namespace (set here if you may) |
| 1 | you | `no-mesh/`: the shop's dev overlay + `shopper` – six Deployments, every Pod `1/1`; the shopper's calls to catalog, review, cart, orders |
| 2 | you | `ambient/`: `istio.io/dataplane-mode: ambient` in every Pod template and the NetworkPolicy `allow-ambient` (HBONE on 15008) – new Pods, still `1/1`, annotation `ambient.istio.io/redirection: enabled`, the shop still answers `200` |
| 3 | you | `waypoint/`: a waypoint (Gateway API, class `istio-waypoint`), `istio.io/use-waypoint: waypoint` on every Service, a PodMonitor for the waypoint – the Kiali graph of the whole shop |

Needs: `oc` logged in, OpenShift Service Mesh 3 in ambient mode (Istio `default` and IstioCNI
with profile `ambient`, a ZTunnel, Kiali; OVN-Kubernetes `routingViaHost: true`), the Gateway API
CRDs and user workload monitoring. The cluster pulls the shop's dev images from quay.io and
`registry.redhat.io/ubi9/ubi:9.9`.

The files:

| File | Content |
|---|---|
| `no-mesh/kustomization.yaml` | the shop's `deploy/overlays/dev` plus `shopper.yaml` |
| `no-mesh/shopper.yaml` | Deployment `shopper` (UBI 9, `curl`): every second products, a product, reviews, a review, the cart; every 10th round an order – one line `<time> <method> <path> <status> <seconds>` – and the NetworkPolicy `allow-shopper-to-web` |
| `ambient/kustomization.yaml` | `../no-mesh`, the ambient label in every Pod template, `allow-ambient.yaml` |
| `ambient/allow-ambient.yaml` | NetworkPolicy: HBONE (15008) between the Pods of the namespace, health probes from `169.254.7.127` |
| `waypoint/kustomization.yaml` | `../ambient`, `waypoint.yaml`, `podmonitor.yaml`, `istio.io/use-waypoint: waypoint` on every Service |
| `waypoint/waypoint.yaml` | Gateway `waypoint`, class `istio-waypoint`, listener `mesh` on 15008/HBONE |
| `waypoint/podmonitor.yaml` | PodMonitor for the waypoint (15090, `/stats/prometheus`) and a NetworkPolicy that lets the monitoring stack reach it |
| `admin/namespace-in-mesh.sh` | cluster-admin: shows the mesh, applies `ztunnel-podmonitor.yaml`, labels the namespaces `istio-discovery=enabled` |
| `admin/ztunnel-podmonitor.yaml` | PodMonitor for ztunnel (15020, `/stats/prometheus`) – the L4 metrics of ambient Pods |

Why the extra NetworkPolicy: in ambient mode the calls between Pods arrive as HBONE on port
**15008**, not on the application port. The shop's default deny only opens 8080 – without
`allow-ambient` the calls in the mesh are dropped. Calls from outside the mesh (the router) still
arrive on 8080 and keep using `allow-from-router`.

Kiali shows edges only for metrics Prometheus has: ztunnel's TCP metrics (needs the ztunnel
PodMonitor) and the waypoint's HTTP metrics (needs the waypoint PodMonitor). Set the graph to
**Last 5m** and tick HTTP and TCP under **Traffic**.
