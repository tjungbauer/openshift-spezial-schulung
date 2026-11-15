# Demo 17 – One request, three signals

The shop (web, catalog, cart, orders, review) and a `client` Pod with `curl`. One order is
followed through the shop: first in the JSON logs by its request id, then – after one
environment variable – as a trace. A delay in catalog shows what a trace is for. Runs in its
own project `demo-traces`.

```bash
cd demos/17_logs-traces
./demo-17-logs-traces.sh              # all steps (about 8 minutes)
./demo-17-logs-traces.sh 3            # one step (creates what it needs)
./demo-17-logs-traces.sh cleanup
```

Needs `oc` (logged in) and nothing else on the cluster: **no** logging or tracing stack. The logs
come from `oc logs`; the traces go to a **Jaeger** Pod (`jaeger.yaml`) – a stand-in for what
OpenShift uses (OpenTelemetry collector + Tempo, shown in Observe › Traces), so the demo runs
anywhere. The cluster pulls `quay.io/tjungbau/shop-*-dev:shop-test-dev`,
`registry.redhat.io/ubi9/ubi:9.9` and `quay.io/jaegertracing/jaeger:2.10.0`. Keep a browser tab
for the Jaeger UI ready – the script prints the link to the trace.

| Step | What you see |
|---|---|
| 0 | one call through web – `X-Request-ID` in the answer, one JSON log line in catalog |
| 1 | an order with our own request id – the same id in web, orders and catalog |
| 2 | Jaeger, `OTEL_EXPORTER_OTLP_ENDPOINT` on orders and catalog – the log lines get a `trace_id`, the trace in Jaeger: orders → catalog |
| 3 | 800 ms delay in catalog – all three services log ~800 ms, the trace shows which span spent it; fault off |

The files:

| File | Content |
|---|---|
| `kustomization.yaml` | the shop's `deploy/base` (no NetworkPolicies, no monitoring) with the dev images, plus `client.yaml` and `patch-catalog.yaml` |
| `patch-catalog.yaml` | `ADMIN_TOKEN=demo-token` for catalog – for `POST /admin/fault` |
| `client.yaml` | Pod `client` (UBI 9 with `curl`) – places the orders through web, switches the fault |
| `jaeger.yaml` | Jaeger all-in-one (in memory): OTLP/HTTP on 4318, UI on 16686, Route `jaeger` |

What the shop does (`shop/common/shopkit.py`): one JSON line per request on stdout with
`request_id` (from `X-Request-ID`, passed on to the next service) and – when tracing is on –
`trace_id`. Tracing is OpenTelemetry, off until `OTEL_EXPORTER_OTLP_ENDPOINT` is set; the
`traceparent` header carries the trace from orders to catalog. web (nginx) passes the request id
on, but does not create spans – the trace starts in orders.

By hand, in the project `demo-traces`:

```bash
oc apply -k .
oc exec client -- curl -s -X POST http://web:8080/api/orders/orders \
  -H 'X-Request-ID: by-hand-1' -H 'Content-Type: application/json' \
  -d '{"items": [{"product_id": "mug", "quantity": 1}]}'
for d in web orders catalog; do oc logs deployment/$d --since=10m | grep -F by-hand-1; done

oc apply -f jaeger.yaml
oc set env deployment/orders deployment/catalog OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318
oc exec client -- curl -s -X POST http://catalog:8080/admin/fault \
  -H 'Authorization: Bearer demo-token' -H 'Content-Type: application/json' -d '{"delay_ms": 800}'
# … place another order, open https://$(oc get route jaeger -o jsonpath='{.spec.host}')
oc delete -f jaeger.yaml
oc delete -k .
```
