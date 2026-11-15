# Demo 16 – From metric to alert

The shop's catalog service, a steady load (about 10 requests per second) and a `client` Pod with
`curl`. One counter and one histogram in the code become a scrape target, PromQL queries and an
alert that fires. Runs in its own project `demo-monitoring`.

```bash
cd demos/16_metrics-alerts
./demo-16-metrics-alerts.sh              # all steps (about 8 minutes)
./demo-16-metrics-alerts.sh 3            # one step (creates what it needs)
./demo-16-metrics-alerts.sh cleanup
```

Needs `oc` (logged in), **user workload monitoring** enabled on the cluster, and the right to
create ServiceMonitors and PrometheusRules in the project (`monitoring-edit`, or admin); the
cluster pulls `quay.io/tjungbau/shop-catalog-dev:shop-test-dev` and
`registry.redhat.io/ubi9/ubi:9.9`. The queries and the alert are shown in the console – keep a
browser tab with **Observe › Metrics** and **Observe › Alerting** open next to the terminal; the
script prints the links.

| Step | What you see |
|---|---|
| 0 | `/metrics` of catalog: `shop_http_requests_total` (counter) and `shop_http_request_duration_seconds_bucket` (histogram) |
| 1 | `servicemonitor.yaml` – the target in Observe › Targets is `Up` |
| 2 | four queries: requests/s by status and by endpoint, p95 latency, error ratio |
| 3 | `prometheusrule.yaml`, 30 % errors + 300 ms delay injected – `CatalogErrorRateHigh` pending, then firing; fault off |

The files:

| File | Content |
|---|---|
| `catalog.yaml` | Deployment `catalog` (1 replica, `ADMIN_TOKEN=demo-token`) and Service with the label the ServiceMonitor selects |
| `load.yaml` | Deployment `load` – product list and single products, every 20th call a 404 |
| `client.yaml` | Pod `client` (UBI 9 with `curl`) – reads `/metrics`, switches the faults |
| `servicemonitor.yaml` | scrape the Service port `http`, path `/metrics`, every 30 s |
| `prometheusrule.yaml` | `CatalogErrorRateHigh` (5xx > 5 % for 1 m) and `CatalogSlow` (p95 > 500 ms for 2 m) |

The queries (Observe › Metrics):

```text
sum by (status) (rate(shop_http_requests_total{namespace="demo-monitoring",job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))

sum by (endpoint) (rate(shop_http_requests_total{namespace="demo-monitoring",job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))

histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket{namespace="demo-monitoring",job="catalog",endpoint!~"/health/.*|/metrics"}[2m])))

sum(rate(shop_http_requests_total{namespace="demo-monitoring",job="catalog",endpoint!~"/health/.*|/metrics",status=~"5.."}[1m]))
  / sum(rate(shop_http_requests_total{namespace="demo-monitoring",job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))
```

`endpoint!~"/health/.*|/metrics"` leaves the probes and the scrapes out – they are counted
too, and they are never slow and never fail.

By hand, in the project `demo-monitoring`:

```bash
oc apply -f catalog.yaml -f client.yaml -f load.yaml
oc exec client -- curl -s http://catalog:8080/metrics | grep '^shop_http_requests_total'
oc apply -f servicemonitor.yaml -f prometheusrule.yaml
oc exec client -- curl -s -X POST http://catalog:8080/admin/fault \
  -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' \
  -d '{"error_rate": 0.3, "delay_ms": 300}'
# … Observe › Alerting: CatalogErrorRateHigh pending, then firing
oc exec client -- curl -s -X POST http://catalog:8080/admin/fault \
  -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' \
  -d '{"error_rate": 0, "delay_ms": 0}'
oc delete -f prometheusrule.yaml -f servicemonitor.yaml -f load.yaml -f client.yaml -f catalog.yaml
```
