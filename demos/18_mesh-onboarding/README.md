# Demo 18 – The shop joins the mesh (ambient mode)

Who does what when an application joins OpenShift Service Mesh 3 in **ambient mode**: the
**cluster-admin** has installed the mesh (profile ambient, ztunnel on every node) and puts the
namespace into its scope – the **application team** adds one label to every Pod template and,
for L7 features, a waypoint. No sidecar: the Pods stay `1/1`. The shop runs in its own project
`demo-mesh`. About 6 minutes.

```bash
cd demos/18_mesh-onboarding
./demo-18-mesh-onboarding.sh              # all steps
./demo-18-mesh-onboarding.sh 2            # one step (creates what it needs)
./demo-18-mesh-onboarding.sh cleanup
```

| Step | Who | What you see |
|---|---|---|
| 0 | cluster-admin | `oc get istio,istiocni,ztunnel`, profile `ambient`, the ztunnel DaemonSet, the `discoverySelectors` and the label `istio-discovery=enabled` on the namespace (set here if you may) |
| 1 | you | the shop from `no-mesh/` – five Deployments, every Pod `1/1` |
| 2 | you | `ambient/` adds `istio.io/dataplane-mode: ambient` to every Pod template – new Pods, still `1/1`, annotation `ambient.istio.io/redirection: enabled`; 30 calls through the Route |
| 3 | you | `waypoint/`: a waypoint (Gateway API, class `istio-waypoint`) and `istio.io/use-waypoint: waypoint` on every Service – a `waypoint` Pod, 30 calls, the Kiali graph with HTTP metrics |

Needs: `oc` logged in, OpenShift Service Mesh 3 in ambient mode (Istio `default` and IstioCNI
with profile `ambient`, a ZTunnel, Kiali; OVN-Kubernetes `routingViaHost: true`) and the
Gateway API CRDs. Run it as **cluster-admin** – or let a cluster-admin prepare the namespace
once and run it as a normal user (step 0 then only shows what is there):

```bash
./admin/namespace-in-mesh.sh demo-mesh       # cluster-admin, once
```

The files:

| File | Content |
|---|---|
| `no-mesh/kustomization.yaml` | the shop's `deploy/base` with the dev images – no NetworkPolicies, no monitoring |
| `ambient/kustomization.yaml` | `../no-mesh` plus a JSON patch on every Deployment: `istio.io/dataplane-mode: ambient` in the Pod template |
| `waypoint/kustomization.yaml` | `../ambient` plus `waypoint.yaml` and a patch on every Service: `istio.io/use-waypoint: waypoint` |
| `waypoint/waypoint.yaml` | Gateway `waypoint`, class `istio-waypoint`, listener `mesh` on 15008/HBONE |
| `admin/namespace-in-mesh.sh` | the cluster-admin part for one namespace: shows the mesh and `discoverySelectors`, sets `istio-discovery=enabled` |

On the training cluster istiod watches only namespaces with `istio-discovery=enabled`. The
students cannot label namespaces – they put the ambient label into their Pod templates (that
rolls out new Pods once) and label their Services for the waypoint, all in Git. A namespace
label `istio.io/dataplane-mode=ambient` (platform team) would put running Pods in without a
restart. Cleanup deletes the shop and the waypoint; the namespace label stays.
