# Lab 8 – Metrics, alerts and logs (30 min)

The shop has been exposing metrics since the Day 2 start – nobody looked at them yet. Now you
check that Prometheus scrapes them, ask them questions with PromQL, put an alert into Git, make
it fire – and find the log lines behind the alert.

**You will learn**

- how a ServiceMonitor tells the user workload Prometheus what to scrape
- how to check that a target is scraped – and why `up` is the first query to run
- `rate()` for counters and `histogram_quantile()` for latency
- how an alert travels: PrometheusRule in Git → pending → firing
- how to get from an alert to the log lines – and to one request through two services

**How to work through this lab**

- Run every command from the folder `lab-08/`. Your shop repository is `$SHOP_WORK`
  (`~/shop-gitops`); the commands write into it with `"$SHOP_WORK/…"` and
  `git -C "$SHOP_WORK"` – you never change directories.
- Changes to the shop go through Git: **commit, push, refresh**. Lab tools
  (`files/traffic.yaml`, `files/fault.sh`) are not part of the shop and do not go to Git.
- The queries run in the web console: **Observe › Metrics** and **Observe › Alerting**, with
  your shop namespace selected. Keep a browser tab open next to the terminal.

## Before you start

Lab 7 must be done: `shop-dev` is `Synced` / `Healthy`, catalog runs with 2 replicas (HPA) and
an admin token.

```bash
export NS=sbx-wsXX                      # your namespace – your Argo CD runs here
export SHOP_NS=$NS-shop                 # the shop runs here
export SHOP_WORK=~/shop-gitops          # your local copy of the shop repository
oc project $SHOP_NS
```

The command after every push (as in lab 7):

```bash
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
```

The console pages of this lab:

```bash
echo "$(oc whoami --show-console)/monitoring/query-browser?namespace=$SHOP_NS"
echo "$(oc whoami --show-console)/monitoring/alerts?namespace=$SHOP_NS"
```

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | The ServiceMonitors | 4 min |
| 2 | Is it scraped? | 4 min |
| 3 | Query it | 7 min |
| 4 | An alert | 5 min |
| 5 | Make it fire | 5 min |
| 6 | Find the logs | 5 min |

---

### 1 · The ServiceMonitors

**Goal:** know what Prometheus scrapes in your namespace – and start some traffic, so there is
something to see.

```bash
oc get servicemonitor
oc get servicemonitor catalog -o yaml | grep -A4 -E '^  (selector|endpoints):'
oc get service catalog -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}  {.spec.ports[*].name}{"\n"}'
cat "$SHOP_WORK/components/monitoring/kustomization.yaml"
```

The ServiceMonitors came with the dev overlay (component `monitoring`) – they are in your Git
repository since the Day 2 start.

Now the traffic – about 5 requests per second through web, as a browser would ask:

```bash
cat files/traffic.yaml
oc apply -f files/traffic.yaml
oc rollout status deployment/traffic --timeout=120s
```

**Expected result:** four ServiceMonitors – `cart`, `catalog`, `orders`, `review`. Each selects
the **Service** with the label `app.kubernetes.io/name: <name>` and scrapes its port **by name**
(`http`), path `/metrics`, every 30 s. web has none – nginx exposes no metrics.

> **What to notice:** a ServiceMonitor never names a Pod or a port number. It selects Services
> by label and the port by name – Prometheus then scrapes **every Pod** behind that Service.
> With two catalog replicas, that is two targets.

---

### 2 · Is it scraped?

**Goal:** prove that Prometheus reaches every target – before you trust any graph.

Open **Observe › Metrics** (the first link above), select your shop namespace and run:

```text
up
```

Then, to see what one target delivers:

```text
shop_http_requests_total{job="catalog"}
```

**Expected result:** `up` returns **five** series with the value `1`: `job="catalog"` twice (two
replicas, one per Pod), `cart`, `orders` and `review` once. `shop_http_requests_total` lists one
series per Pod, method, endpoint and status – for example `endpoint="/products/{product_id}"`,
`status="200"`.

> **What to notice:** `up` is written by Prometheus itself for every target – `1` scraped, `0`
> failed. A target that is missing completely means the ServiceMonitor selects nothing (label or
> port name wrong). A target with `0` means it was found but could not be scraped (NetworkPolicy,
> wrong path). The shop's NetworkPolicies have a rule `allow-from-monitoring` for that.

**If it does not work**

- No result at all – wrong namespace selected at the top of the page, or no ServiceMonitors
  (task 1).
- `up` is `0` – `oc get networkpolicy allow-from-monitoring`; the shop's default deny blocks
  Prometheus without it.
- "Forbidden" – user workload monitoring is not enabled on the cluster (ask the trainer).

---

### 3 · Query it

**Goal:** turn counters and histograms into answers: how many requests per second, how many
fail, how fast is catalog.

Paste the queries one by one into **Observe › Metrics**. Requests per second, by status:

```text
sum by (status) (rate(shop_http_requests_total{job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))
```

The same, by endpoint:

```text
sum by (endpoint) (rate(shop_http_requests_total{job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))
```

The p95 latency in seconds – 95 % of the requests were faster than this:

```text
histogram_quantile(0.95, sum by (le) (rate(shop_http_request_duration_seconds_bucket{job="catalog",endpoint!~"/health/.*|/metrics"}[2m])))
```

The error ratio – the share of 5xx answers:

```text
sum(rate(shop_http_requests_total{job="catalog",status=~"5..",endpoint!~"/health/.*|/metrics"}[1m])) / sum(rate(shop_http_requests_total{job="catalog",endpoint!~"/health/.*|/metrics"}[1m]))
```

**Expected result:** about 5 requests per second with `status="200"`, split between `/products`
and `/products/{product_id}`; p95 a few milliseconds; the error ratio returns **no data** – there
are no 5xx answers yet, so the numerator is empty.

> **What to notice:** a counter only goes up – `rate(x[1m])` makes it "per second, averaged over
> one minute". `sum by (…)` adds up both Pods. `endpoint!~"/health/.*|/metrics"` leaves out the
> probes and the scrapes: they are counted too, never fail and are never slow – they would hide
> what your users see.

---

### 4 · An alert

**Goal:** an alert for catalog in Git: more than 5 % of the calls fail for 1 minute.

```bash
cat files/prometheusrule-catalog.yaml
diff "$SHOP_WORK/overlays/dev/kustomization.yaml" files/kustomization-dev-alert.yaml
cp files/prometheusrule-catalog.yaml "$SHOP_WORK/overlays/dev/"
cp files/kustomization-dev-alert.yaml "$SHOP_WORK/overlays/dev/kustomization.yaml"
oc kustomize "$SHOP_WORK/overlays/dev" | grep -A3 '^kind: PrometheusRule'
git -C "$SHOP_WORK" add .
git -C "$SHOP_WORK" commit -m "dev: alerts for catalog"
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc get prometheusrule
```

Open **Observe › Alerting** (the second link above) and switch to the tab **Alerting rules**.

**Expected result:** apart from the comment at the top, the `diff` shows one added line:
`- prometheusrule-catalog.yaml`.
`oc get prometheusrule` lists `catalog`; in the console both rules – `CatalogErrorRateHigh` and
`CatalogSlow` – appear within a minute, state **inactive**.

> **What to notice:** the expression of `CatalogErrorRateHigh` is your error-ratio query from
> task 3 plus `> 0.05`. `for: 1m` is the protection against noise: the expression must be true
> for a full minute before anybody is alerted. The rule does not name the namespace – user
> workload monitoring adds it, a rule only ever sees its own namespace.

**If it does not work**

- `oc get prometheusrule` is empty – `shop-dev` not synced yet: refresh again, check
  `oc -n $NS get applications.argoproj.io shop-dev`.
- The rule is missing in the console – the console needs up to a minute; check the namespace
  selection.

---

### 5 · Make it fire

**Goal:** 30 % of the catalog calls fail – watch the alert go from inactive to pending to
firing.

```bash
cat files/fault.sh
./files/fault.sh '{"error_rate": 0.3}'
```

Watch **Observe › Alerting**, and the requests by status from task 3 in **Observe › Metrics**.
Reload the shop in the browser a few times, too. After the alert has been **firing** for a
moment, switch the fault off again:

```bash
./files/fault.sh '{"error_rate": 0}'
```

**Expected result:** `fault.sh` prints the new fault settings once per catalog Pod. The `503`
line appears in the status graph within a minute. `CatalogErrorRateHigh` turns **pending** after
about one minute and **firing** about one minute later, with the description "…% of the catalog
API calls answered with 5xx". In the shop, some product lists fail to load. After the fault is
off, the alert resolves within two minutes.

> **What to notice:** pending means "the expression is true, `for:` has not passed yet" – only
> firing alerts go to the Alertmanager. The alert describes a **symptom** your users feel
> (failed calls), not a cause (CPU, a Pod restart). That is what alerts are for – the cause is
> what you look for next, in the logs.

**If it does not work**

- `fault.sh` answers `401 invalid admin token` – the admin token of lab 7 is missing:
  `oc get deployment catalog -o yaml | grep -A1 ADMIN_TOKEN`.
- The alert stays inactive – is there traffic? `oc get deployment traffic`; the 503 line must
  show in task 3's status query.

---

### 6 · Find the logs

**Goal:** from the alert to the log lines – and from one failed call in catalog to the same
request in web.

The shop writes one JSON line per request to stdout. The 503 answers of the last ten minutes:

```bash
oc logs -l app.kubernetes.io/name=catalog --tail=-1 --since=10m --prefix | grep '"status": 503' | tail -3
```

Take one request id and follow it:

```bash
ID=$(oc logs -l app.kubernetes.io/name=catalog --tail=-1 --since=10m | grep '"status": 503' | tail -1 | sed -E 's/.*"request_id": "([^"]+)".*/\1/')
echo $ID
oc logs -l app.kubernetes.io/name=catalog --tail=-1 --since=10m --prefix | grep "$ID"
oc logs deployment/web --since=10m | grep "$ID"
oc logs -l app.kubernetes.io/name=catalog --tail=-1 --since=10m | grep '"message": "faults changed"'
```

**Expected result:** catalog lines like
`{"time": "…", "level": "info", "service": "catalog", "pod": "catalog-…", "message": "request", "request_id": "…", "method": "GET", "path": "/products", "status": 503, "duration_ms": …}`.
The same request id appears **once in catalog and once in web** – web with
`"path":"/api/catalog/products"` and `"status":503`. The last command shows who switched the
fault on, and when (`level` `warning`).

> **What to notice:** web creates the request id (or keeps the caller's `X-Request-ID`) and
> passes it on; every service logs it. One search finds a request in every service it touched.
> The 503 lines have `"level": "info"` – the shop logs every request line at info. Filter on
> `status`, not on `level`.

**Observe › Logs** – on a cluster with the logging stack (LokiStack and the Cluster Logging
Operator) the same search works across Pods and days, also for Pods that are gone. In LogQL:
`{kubernetes_namespace_name="sbx-wsXX-shop", kubernetes_container_name="catalog"} | json | status >= 500`.
`oc logs` only knows the Pods that run now.

**If it does not work**

- No 503 lines – more than ten minutes since task 5: use `--since=30m`, or run task 5 again.
- `$ID` is empty – the `grep` found nothing (see above); `echo $ID` must print a 32-character
  id.
- Nothing in web – the call came from somewhere else than web (for example the shop UI in your
  browser: then it is in web as well; only calls from `oc exec` straight to catalog are not).

---

## Done early? Bonus

- **The slow alert:** `./files/fault.sh '{"delay_ms": 800}'` – watch the p95 query and
  `CatalogSlow` (pending after ~1 min, firing after `for: 2m`). Why does it take longer than the
  error alert? Switch it off: `./files/fault.sh '{"delay_ms": 0}'`.
- **Two Pods, one broken:** `./files/fault.sh '{"error_rate": 1}' <one catalog Pod>` – what is
  the error ratio now, and does the alert fire? Then add `pod` to the `sum by` of the status
  query and find the broken Pod.

## Cleanup

Stop the traffic – the alerts stay in Git, lab 9 continues with this state:

```bash
./files/fault.sh '{"error_rate": 0, "delay_ms": 0}'
oc delete -f files/traffic.yaml
```
