# Demo 15 – Requests, limits and the HPA

Two copies of the shop's catalog service – one without, one with a CPU limit –, load generators
(curl loops in UBI Pods) and a `client` Pod that measures latency. Runs in its own project
`demo-resources`.

```bash
cd demos/15_resources-hpa
./demo-15-resources-hpa.sh              # all steps (about 12 minutes – mostly waiting for metrics)
./demo-15-resources-hpa.sh 2            # one step (creates what it needs)
./demo-15-resources-hpa.sh cleanup
```

Needs `oc` (logged in) and cluster metrics (`oc adm top pods` must work); the cluster pulls
`quay.io/tjungbau/shop-catalog-dev:shop-test-dev` and `registry.redhat.io/ubi9/ubi:9.9`.

| Step | What you see |
|---|---|
| 0 | requests and limits per Pod (QoS `Burstable`) next to the real usage from `oc adm top pods` |
| 1 | the same load on both copies: `catalog-limited` sticks at ~50m and gets slow, `catalog` takes spare CPU – latency side by side, PromQL for the throttling ratio |
| 2 | HPA 1–5 replicas at 60 % of the CPU request; three load Pods – the HPA scales out |
| 3 | load stops – utilisation drops at once, the replicas stay for the stabilisation window (120 s here, default 300 s) |

The files:

| File | Content |
|---|---|
| `catalog.yaml` | Deployments `catalog` (request 50m, no CPU limit) and `catalog-limited` (limit 50m), one Service each |
| `load.yaml` | `load-catalog` and `load-limited` – 0 replicas; each replica runs 4 parallel curl loops |
| `hpa.yaml` | HorizontalPodAutoscaler for `catalog` (autoscaling/v2, `behavior.scaleDown`) |
| `client.yaml` | Pod `client` (UBI 9 with `curl`) – measures the response time |

Queries for Observe › Metrics (replace the namespace):

```text
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="demo-resources",container="catalog"}[2m]))

sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="demo-resources",container="catalog"}[2m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="demo-resources",container="catalog"}[2m]))
```

By hand, in the project `demo-resources`:

```bash
oc apply -f client.yaml -f catalog.yaml -f load.yaml
oc adm top pods

# throttling: the same load on both copies
oc scale deployment/load-catalog deployment/load-limited --replicas=1
oc exec client -- sh -c 'for i in $(seq 20); do curl -s -o /dev/null -w "%{time_total}\n" http://catalog-limited:8080/products; done'
oc scale deployment/load-catalog deployment/load-limited --replicas=0

# HPA
oc apply -f hpa.yaml
oc scale deployment/load-catalog --replicas=3
oc get hpa catalog -w
oc scale deployment/load-catalog --replicas=0

oc delete -f hpa.yaml -f load.yaml -f catalog.yaml -f client.yaml
```
