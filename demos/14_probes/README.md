# Demo 14 – Probes at work

The catalog service of the shop on its own – two replicas with the shop's three probes – and a
`client` Pod with `curl`. Four faults, four different reactions. Runs in its own project
`demo-probes`.

```bash
cd demos/14_probes
./demo-14-probes.sh              # all steps
./demo-14-probes.sh 3            # one step (creates catalog and client if needed)
./demo-14-probes.sh cleanup
```

Needs `oc` (logged in); the cluster pulls `quay.io/tjungbau/shop-catalog-dev:shop-test-dev`
and `registry.redhat.io/ubi9/ubi:9.9`.

| Step | Fault | What you see |
|---|---|---|
| 0 | – | `catalog.yaml`: startup, readiness, liveness; the EndpointSlice; six calls through the Service |
| 1 | `fail_ready` on one Pod | `READY 0/1`, `RESTARTS 0`, the Pod leaves the EndpointSlice, all calls go to the other Pod – and it comes back |
| 2 | 40 s start (`FAULT_STARTUP_DELAY_S`) | `slow-with-startup`: 0/1 for 40 s, no restart. `slow-no-startup`: liveness asks `/health/ready` while starting – restarted again and again |
| 3 | liveness path `/health/livez` | the app serves, the kubelet restarts it every ~30 s (`Liveness probe failed … 404`) |
| 4 | image tag that does not exist | the new Pod hangs in `ImagePullBackOff`, the old Pods keep serving, `ProgressDeadlineExceeded` after 60 s, `oc rollout undo` |

The files:

| File | Content |
|---|---|
| `catalog.yaml` | Deployment `catalog` (2 replicas, `ADMIN_TOKEN=demo-token`, `progressDeadlineSeconds: 60`) and Service |
| `client.yaml` | Pod `client` (UBI 9 with `curl`) – calls the Service and single Pod IPs |
| `slow-start.yaml` | `slow-with-startup` and `slow-no-startup` – the same slow app, with and without a startup probe |

By hand, in the project `demo-probes`:

```bash
oc apply -f client.yaml -f catalog.yaml
oc get endpointslice -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{"  ready="}{.conditions.ready}{"\n"}{end}'

# 1 – one Pod unready
POD=$(oc get pods -l app.kubernetes.io/name=catalog -o jsonpath='{.items[0].metadata.name}')
IP=$(oc get pod $POD -o jsonpath='{.status.podIP}')
oc exec client -- curl -s -X POST http://$IP:8080/admin/fault \
  -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' -d '{"fail_ready": true}'
oc get pods -l app.kubernetes.io/name=catalog
oc exec client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://catalog:8080/info; echo; done'

# 2 – slow start, with and without a startup probe
oc apply -f slow-start.yaml
oc get pods -l app.kubernetes.io/part-of=demo-14 -w

# 3 – a wrong liveness path
oc patch deployment catalog --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health/livez"}]'
oc get events --field-selector reason=Unhealthy

# 4 – a broken image
oc set image deployment/catalog catalog=quay.io/tjungbau/shop-catalog-dev:does-not-exist
oc rollout status deployment/catalog --timeout=90s
oc rollout undo deployment/catalog

oc delete -f slow-start.yaml -f catalog.yaml -f client.yaml
```
