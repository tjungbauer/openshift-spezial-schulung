# ACME shop – sample application for the advanced OpenShift training

A small but realistic web shop: five services, one browser UI, everything
configurable through environment variables and mounted files. It is the shared
code base for all labs of the two-day training – images, Helm, Kustomize,
Argo CD, probes, metrics, logging, tracing, Service Mesh, hardening and CI.

![The shop in the browser](docs/screenshot.png)

| | |
|---|---|
| ![Cart drawer](docs/screenshot-cart.png) | ![catalog 2.x (canary look) and orders unreachable](docs/screenshot-orders-down.png) |
| the cart drawer | catalog **2.0.0** (purple, "new" badges) – and the status panel showing that **orders is unreachable** |

ACME is a fictional company. Product pictures are emoji – no logos, no trademarks.

---

## Architecture

```mermaid
flowchart LR
    browser([Browser]) -- HTTPS --> route[Route web<br/>edge TLS]
    route --> web["web<br/>nginx: UI + /api proxy"]
    web -- /api/catalog/ --> catalog["catalog<br/>FastAPI · products, stock"]
    web -- /api/cart/ --> cart["cart<br/>FastAPI · carts in memory"]
    web -- /api/orders/ --> orders["orders<br/>FastAPI · orders"]
    web -. /api/review/ (optional) .-> review["review<br/>FastAPI · star ratings"]
    orders -- reserve stock --> catalog
    orders --> sqlite[("SQLite<br/>emptyDir / PVC")]
    orders -. DATABASE_URL set .-> pg[("PostgreSQL 16<br/>StatefulSet")]
    prom([Prometheus]) -. /metrics .-> catalog & cart & orders & review
```

| Service | What it does | Tech |
|---|---|---|
| **web** | Serves the UI (static HTML/CSS/JS, no build step) and proxies `/api/<service>/…` to the backends – the browser only talks to one host. Creates the session cookie `shop_session` and the request id. | nginx 1.30 |
| **catalog** | Products, details and stock. Products come from `catalog/products.json` in the image (overridable via a mounted ConfigMap). Stock lives in memory, per pod. **Version 2.x** marks new products with a badge and switches the UI to a purple accent – for canary demos. | Python 3.12, FastAPI |
| **cart** | One cart per session (session id from web), kept in memory – lost on restart, not shared between replicas (a good lab discussion about state). | Python 3.12, FastAPI |
| **orders** | Places orders: asks catalog to check and reduce the stock (all or nothing), stores the order. SQLite in `/var/lib/shop` by default, PostgreSQL when `DATABASE_URL` is set. | Python 3.12, FastAPI |
| **review** | Star ratings 1–5 per product, from `review/reviews.json` in the image (random but fixed ratings; overridable via `REVIEWS_FILE`). **Optional:** when review is down, the UI shows no stars – browsing, cart and checkout keep working. | Python 3.12, FastAPI |

The UI shows, for every service, the **version, git revision and pod** that
answered last (footer "Served by" – load balancing, rolling updates and canary
releases become visible), and a **status panel** that turns a backend red when
calls to it fail – that is how NetworkPolicies and probes show in the browser.

### Code layout

```
shop/
├── common/shopkit.py        shared module – edit here, then `make sync-common`
├── catalog/ cart/ orders/ review/  one Python service each:
│   ├── <service>/           main.py (+ shopkit.py copy, __main__.py; orders: db.py, migrate.py)
│   ├── tests/               pytest unit tests
│   ├── requirements.txt     exact pins
│   └── Containerfile, .containerignore
├── web/                     nginx.conf, upstreams.conf, html/, Containerfile
├── deploy/
│   ├── base/                one folder per service + the Route
│   ├── overlays/dev/        dev images  + networkpolicies, monitoring, persistent-orders → project shop-dev
│   ├── overlays/prod/       prod images + networkpolicies, monitoring, postgres, backup  → project shop
│   ├── cluster/             cluster-admin, once: enable user workload monitoring
│   └── components/          networkpolicies, monitoring, persistent-orders, postgres, backup
├── local/shop-pod.yaml      the whole shop in one podman pod
├── scripts/                 build, push, run-local, deploy, test, smoke, validate, …
├── docs/                    screenshots
├── deploy.md                every command for dev + prod and the full demo – variables at the top
├── Makefile, VERSION, requirements-dev.txt
```

Room for the labs, without moving anything: `helm/` (chart), `argocd/`
(Applications) and `.github/workflows/` (pipeline) can be added next to `deploy/`.

---

## Quick start

```bash
make test                 # unit tests (creates .venv with python3.12)
make build                # all images, linux/amd64, version + git revision
make run-local            # the whole shop in one podman pod → http://localhost:8080
make smoke                # end-to-end smoke test against the local pod
make stop-local
```

On OpenShift (namespace-admin rights are enough) – dev and prod, as deployed on
2026-11-12. **[deploy.md](deploy.md)** has every command, with the registry and
project names as variables at the top, plus the full demo (NetworkPolicies, PVC,
PostgreSQL, monitoring, load balancing, probes):

```bash
oc login ...
make build
make push   REGISTRY=quay.io/tjungbau IMAGE_SUFFIX=-dev IMAGE_TAG=shop-test-dev   # → shop-<service>-dev:shop-test-dev
make push   REGISTRY=quay.io/tjungbau IMAGE_TAG=shop-test                         # → shop-<service>:shop-test
make deploy OVERLAY=dev  NAMESPACE=shop-dev     # creates the project if needed
make deploy OVERLAY=prod NAMESPACE=shop
make smoke  ROUTE_URL=https://$(oc get route web -n shop-dev -o jsonpath='{.spec.host}')
make smoke  ROUTE_URL=https://$(oc get route web -n shop -o jsonpath='{.spec.host}')
```

Other registries: `make push REGISTRY=nexus.acme.example:5000 IMAGE_PREFIX=workshop/shop-group1-`
→ `nexus…:5000/workshop/shop-group1-catalog:1.0.0`, then
`make deploy … SET_IMAGES=true` with the same variables points the overlay at those images.

| `make …` | |
|---|---|
| `build` | build all images (`PLATFORM=linux/amd64`, `VERSION` from the file `VERSION`, revision from git, `PIP_INDEX_URL` for a mirror) |
| `push` | tag and push to `$REGISTRY/$IMAGE_PREFIX<service>$IMAGE_SUFFIX:$IMAGE_TAG` (tag default: `$VERSION`). Checks first that every repository is reachable, and afterwards pulls each tag back and compares the image ID with the local build |
| `run-local` / `stop-local` | `podman kube play local/shop-pod.yaml` / `podman kube down` |
| `deploy` | `oc apply -k deploy/overlays/$OVERLAY` (default `dev`) into `$NAMESPACE` (default: current project; created if missing), waits for the rollouts. `SET_IMAGES=true` first points the overlay at `$REGISTRY/…` (`kustomize edit set image`) |
| `test` | pytest for catalog, cart, orders (and checks that the `shopkit.py` copies are identical) |
| `smoke` | `scripts/smoke.sh ROUTE_URL` – UI loads, products listed, order placed, every service reports its version |
| `validate` | `kustomize build` + `kubeconform` for base, overlay and every component |
| `check-images` | starts every image as `--user 1000680000:0` and checks `/health/ready` |
| `lint` | shellcheck for all scripts |
| `verify` | `test` + `lint` + `validate` (no container runtime needed) |

Every variable can be overridden: `make build VERSION=2.0.0`, `make … PODMAN="podman --connection podman-machine-default-root"`.

---

## Endpoints

Every backend (catalog, cart, orders) listens on **port 8080** (`PORT`) and has:

| Endpoint | Meaning |
|---|---|
| `GET /health/started` | 200 once started – 503 during `FAULT_STARTUP_DELAY_S` (startup probe) |
| `GET /health/ready` | 200 if it can serve now, including its own dependencies (orders: database reachable). 503 with `FAULT_FAIL_READY`. (readiness probe) |
| `GET /health/live` | 200 while the process is not stuck – never checks other services (liveness probe) |
| `GET /info` | `{"app", "version", "revision", "pod"}` – from `APP_VERSION`, `APP_REVISION`, `HOSTNAME` |
| `GET /metrics` | Prometheus: `shop_http_requests_total{method,endpoint,status}`, `shop_http_request_duration_seconds{method,endpoint}` + one business metric (below) |
| `POST /admin/fault` | change faults at runtime (see below) – only with `ADMIN_TOKEN` |

Every response carries `X-Request-ID`, `X-Shop-App`, `X-Shop-Version`, `X-Shop-Revision` and `X-Shop-Pod`.

| Service | API (through web: `/api/<service>/…`) | Business metric |
|---|---|---|
| catalog | `GET /products` · `GET /products/{id}` · `POST /stock/reserve` `{"items":[{"product_id","quantity"}]}` (all or nothing, 409 if not enough) | `shop_stock_reservations_total{result}` |
| cart | `GET /cart` · `PUT /cart/items/{id}` `{"quantity"}` (0 removes) · `DELETE /cart/items/{id}` · `DELETE /cart` – needs `X-Session-ID` | `shop_cart_items_added_total` (+ gauge `shop_carts`) |
| orders | `POST /orders` `{"items":[…]}` · `GET /orders` (of the session, with `storage` and `persistent`) – needs `X-Session-ID` | `shop_orders_total{result="placed\|rejected\|failed"}` |
| review | `GET /reviews` (average and count for every product) · `GET /reviews/{id}` (with all ratings) | `shop_review_lookups_total{scope}` |
| web | `/` UI · `/info` · `/health/started\|ready\|live` · `/api/catalog\|cart\|orders\|review/…` proxied · `/api/*/admin` and `/api/*/metrics` blocked (404) | – (JSON access log) |

## Configuration (environment variables)

| Variable | Services | Default | Meaning |
|---|---|---|---|
| `PORT` | backends | `8080` | listen port (web: fixed 8080) |
| `APP_VERSION`, `APP_REVISION` | all | from the build args | shown in `/info`, headers, footer. catalog `2.x` = new look |
| `LOG_LEVEL` | backends | `info` | `debug` also logs health/metrics requests |
| `LOG_HEALTH` | backends | `false` | `true`: log probe and metrics requests at info level |
| `PRODUCTS_FILE` | catalog | built-in `products.json` | path of a mounted products file |
| `REVIEWS_FILE` | review | built-in `reviews.json` | path of a mounted ratings file (`{"<product id>": [5, 4, …]}`) |
| `CATALOG_URL` | orders | `http://catalog:8080` | where orders reserves stock |
| `DATA_DIR` | orders | `/var/lib/shop` | SQLite folder (`orders.db`) |
| `DATABASE_URL` | orders | – | `postgresql://user:pass@host:5432/db` → PostgreSQL instead of SQLite |
| `ORDERS_PERSISTENT` | orders | `false` | tells the UI whether SQLite is on a PVC (no "lost on restart" warning) |
| `MIGRATE_TIMEOUT_S` | orders.migrate | `60` | how long the migration waits for the database |
| `ADMIN_TOKEN` | backends | – | enables `POST /admin/fault` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | backends | – | enables tracing (OTLP/HTTP, e.g. `http://otel-collector:4318`) |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, … | backends | service name | standard OpenTelemetry variables |
| `FAULT_*` | backends | off | see fault injection |

web reads its backend addresses from `/etc/nginx/shop/upstreams.conf` (default:
the Services `catalog`, `cart`, `orders` on port 8080). Mount a ConfigMap there to
change them – `local/shop-pod.yaml` does that for the local pod.

To change the products without a new image:

```bash
oc create configmap products --from-file=products.json=my-products.json
oc set volume deployment/catalog --add --name=products -t configmap --configmap-name=products --mount-path=/etc/shop/catalog
oc set env deployment/catalog PRODUCTS_FILE=/etc/shop/catalog/products.json
```

## Fault injection (for demos – all off by default)

| Variable | Effect | Shows |
|---|---|---|
| `FAULT_DELAY_MS=800` | every API request waits 800 ms | latency in metrics and traces, timeouts |
| `FAULT_ERROR_RATE=0.3` | 30 % of the API requests answer **503** | error rates, retries (Service Mesh), red status |
| `FAULT_STARTUP_DELAY_S=40` | `/health/started` and `/ready` stay 503 for 40 s | startup probes |
| `FAULT_FAIL_READY=true` | readiness fails, the process keeps running | readiness probes – the pod leaves the Service, no restart |

Health, `/info`, `/metrics` and `/admin` are never delayed or failed. At runtime
(needs `ADMIN_TOKEN`; not reachable through the Route – use a port-forward):

```bash
oc set env deployment/catalog ADMIN_TOKEN=s3cret
oc port-forward deployment/catalog 8081:8080 &
curl -X POST localhost:8081/admin/fault -H 'Authorization: Bearer s3cret' \
     -H 'Content-Type: application/json' -d '{"error_rate": 0.5, "delay_ms": 300}'
curl -X POST localhost:8081/admin/fault -H 'Authorization: Bearer s3cret' \
     -H 'Content-Type: application/json' -d '{"error_rate": 0, "delay_ms": 0, "fail_ready": false}'
```

The answer is the complete fault state. Without `ADMIN_TOKEN` the endpoint answers 404.

## Logs, request ids and tracing

* One JSON line per request on stdout: `time, level, service, pod, message, request_id, method, path, status, duration_ms` (+ `trace_id` when tracing is on). web logs the same way (`duration_s`).
* web creates `X-Request-ID` (or keeps the caller's) and passes it to the backends; orders passes it on to catalog – one id through the whole request.
* Tracing is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Then FastAPI and httpx are instrumented and W3C trace context (`traceparent`) is propagated between the services.
* Graceful shutdown: on SIGTERM uvicorn stops accepting connections, finishes running requests and exits after at most 20 s; nginx shuts down gracefully on SIGQUIT (`STOPSIGNAL SIGQUIT` in the image). `terminationGracePeriodSeconds: 30`.

## Data

* **Default – no database to set up:** catalog reads products from the image, orders writes SQLite to `/var/lib/shop` on an **emptyDir** – orders are lost when the orders pod is replaced, and the UI says so.
* **`components/persistent-orders`:** SQLite on a 1 Gi PVC, `ORDERS_PERSISTENT=true`, `strategy: Recreate`, 1 replica (SQLite has one writer).
* **`components/postgres` (StatefulSet lab):** PostgreSQL 16 from Red Hat (`registry.redhat.io/rhel9/postgresql-16`, configured only via `POSTGRESQL_USER/PASSWORD/DATABASE`), headless Service `postgres`, Secret `postgres`, Job `orders-migrate` (`python3.12 -m orders.migrate`), a NetworkPolicy for orders → postgres, and orders gets `DATABASE_URL`. orders also migrates by itself before it reports ready, so the order of startup does not matter. Plain `oc apply -k` – no operator, no manual SQL.
* **`components/backup` (needs `postgres`):** CronJob `db-backup` runs `pg_dump --format=custom` every 5 minutes (same PostgreSQL image, credentials from the Secret `postgres`) into the PVC `backups` and keeps the newest 12 dumps. Deployment `backup-viewer` mounts the same PVC read-only – look at the dumps from the terminal with `oc rsh deploy/backup-viewer ls -l /backups` (`hi/python:3.12.16-builder`, the hardened Python image with a shell; `python3.12 -m http.server` for an optional `oc port-forward`; no own image, **no Route** – the dumps contain all orders). The PVC is **ReadWriteOnce** (works with block storage such as AWS EBS): RWO means one *node*, so the CronJob pods have a required pod affinity to the viewer's node, and the viewer uses `strategy: Recreate`. With file storage (CephFS, NFS, EFS) it could be ReadWriteMany without the affinity. A NetworkPolicy lets db-backup reach postgres. Take a backup now: `oc create job db-backup-now --from=cronjob/db-backup`.

## Deploy on OpenShift

```bash
oc apply -n shop-dev -k deploy/overlays/dev     # or: make deploy OVERLAY=dev  NAMESPACE=shop-dev
oc apply -n shop     -k deploy/overlays/prod    # or: make deploy OVERLAY=prod NAMESPACE=shop
```

Switch components on in `deploy/overlays/<dev|prod>/kustomization.yaml`:

```yaml
components:
- ../../components/networkpolicies    # default-deny; router → web; web → backends; orders → catalog; monitoring → all
- ../../components/monitoring         # ServiceMonitors (needs user workload monitoring)
- ../../components/persistent-orders  # SQLite on a PVC
- ../../components/postgres           # PostgreSQL instead of SQLite
- ../../components/backup             # pg_dump CronJob + RWX PVC + backup-viewer (needs postgres)
```

* One namespace, namespace-admin rights: no cluster-scoped objects, no SCC changes, no CRDs (`make validate` checks this). No namespace is set in the manifests – they go into the current project.
* Every Deployment: requests + memory limit, startup/readiness/liveness probes on `/health/*`, `securityContext` (`runAsNonRoot`, no privilege escalation, drop `ALL`, seccomp `RuntimeDefault`) **without** a fixed `runAsUser`, `terminationGracePeriodSeconds: 30`, labels `app.kubernetes.io/name|part-of|version`.
* Route `web`: edge TLS, `insecureEdgeTerminationPolicy: Redirect`.
* web talks to the backends without keepalive, so every request is balanced anew – watch the footer while you scale a backend.
* The Host header to the backends is the service name (`catalog`, …) – what the Service Mesh routes by.

---

## Images

Multi-stage builds: the build stage installs the pinned dependencies with
`pip --target`, the runtime stage gets only Python, the dependencies and the
code – no compiler, no pip cache. File permissions are normalised in the build
stage (`chmod -R a+rX,go-w`), so the images work regardless of the umask on the
build machine.

* Run under **restricted-v2**: any UID, GID 0, port 8080, writes only to `/tmp` (and `/var/lib/shop` for orders, group 0 writable). Numeric `USER 1001`, `EXPOSE 8080`, exec-form `CMD`.
* OCI labels from build args: `org.opencontainers.image.version|revision|created|source|title|vendor`; the same version/revision end up in `APP_VERSION`/`APP_REVISION`.
* Python mirror: `--build-arg PIP_INDEX_URL=https://nexus…/repository/pypi/simple` (`make build PIP_INDEX_URL=…`).
* The runtime images are **distroless** (no shell): debug with `oc debug` or an ephemeral container, not with `oc rsh`.

### Base images (Red Hat Hardened Images – no UBI fallback needed)

Checked in the registry on 2026-11-12: `hi/python` and `hi/nginx` exist with
version tags and `-builder` variants, and work under an arbitrary UID. The
version tags are rebuilt with security fixes; pin to a digest
(`FROM registry…@sha256:…`) for fully reproducible builds.

| Image | Used for | Index digest (multi-arch) | linux/amd64 digest |
|---|---|---|---|
| `registry.access.redhat.com/hi/python:3.12.16-builder` | build stage, Python services | `sha256:9e8f996764dd3231cd49b6bc6847d4b2b6bbd140880c213a5a72e8ebe639dffb` | `sha256:143003d5cc043c23fea6061ca1c5ac962b4e12216e366c0eae3d8792d34e1b09` |
| `registry.access.redhat.com/hi/python:3.12.16` | runtime, Python services | `sha256:ee1a5e29fc88519bbc4a6ff9d7ef36df018608576cbd6c4407435391d901b051` | `sha256:5ac2234b9c12754596cbc7230e9ea962eff1fcc20e90f04a5f29ffdded221cf1` |
| `registry.access.redhat.com/hi/nginx:1.30.6-builder` | build stage, web | `sha256:bb25cd5316c4cfa39ea380ed6988b8dd2f52caf06cd6789760ac02ff60bae29c` | `sha256:288e7a6b0b61e4c6181ec9d272e52bd49fd577fbc781efc3a641c579dc90d8d8` |
| `registry.access.redhat.com/hi/nginx:1.30.6` | runtime, web | `sha256:a6fa6830351d87da75272bc7597af100f52b5ed45fcb58be71ef1336e25e6df1` | `sha256:4aaa7a9caa6750863b172634fa7df1c76c28ea71f27cb25dd5ee0231ffe4b52a` |
| `registry.redhat.io/rhel9/postgresql-16:9.9-1793851884` | postgres component | `sha256:9fa2dd4950c4e4c92799b55e68f68b4285548d48d58d7300f2bf5316474de811` | `sha256:77012bbf9a6de59edb18793ec97ffb6b7c43adc630bbfae30f9f096ece0a6f99` |

`hi/python` has no gcc: every dependency must come as a wheel (that is why
orders uses `psycopg[binary]`). The PostgreSQL image is only on
`registry.redhat.io` (terms acceptance) – OpenShift pulls it with the cluster's
global pull secret; locally you need `podman login registry.redhat.io`.

### Python dependencies

Direct: `fastapi`, `uvicorn`, `prometheus_client`, `httpx`, `opentelemetry-sdk`,
`opentelemetry-exporter-otlp-proto-http`, `opentelemetry-instrumentation-fastapi`,
`opentelemetry-instrumentation-httpx`; orders also `psycopg[binary]`. Tests: `pytest`.
Every `requirements.txt` pins **all** packages exactly (direct and transitive,
from `pip freeze` in a clean Python 3.12 venv).

---

## Verification (2026-11-12, macOS on Apple Silicon, podman 6.1.4)

| Check | Result |
|---|---|
| Unit tests (`make test`) | catalog 17, cart 9, orders 13, review 10 – all pass |
| Images build for `linux/amd64` (`make build`) | all 4 |
| `--user 1000680000:0` + `/health/ready` (`make check-images`) | all 4 ready, process UID 1000680000 |
| Local end-to-end (`make run-local` + `make smoke`) | 10/10 checks pass; UI checked with Playwright – no console errors (screenshots above) |
| Fault injection, graceful shutdown | slow start, fail-ready, admin endpoint, a 4 s request finishes after SIGTERM |
| PostgreSQL variant | PostgreSQL 16 as UID 1000680000 + `orders.migrate` + order placed and stored |
| Manifests (`make validate`) | base, overlay, each component and all together: kubeconform valid, only namespaced kinds |
| `make lint` | shellcheck clean |
| `make push` (quay.io/tjungbau, dev + prod) | 8 images pushed, every tag pulled back with the same image ID |
| `make deploy` on OpenShift 5.0.1 (Kubernetes 1.36) | `shop-dev` and `shop`: all pods ready under `restricted-v2` with a UID from the project range, no PodSecurity warnings |
| `make smoke` through both Routes | 10/10 each; prod UI checked in the browser (`docs/screenshot-openshift.png`) |
| networkpolicies (both projects) | Route works; a test pod in the project and one from the other project get no answer from catalog |
| persistent-orders (shop-dev) | PVC bound (gp3-csi), switch to `Recreate` applied cleanly, an order survives deleting the orders pod |
| postgres (shop) | image pulled from `registry.redhat.io`, migration Job complete, orders stored in PostgreSQL, still there after restarting `postgres-0` and orders |
| monitoring (both projects) | user workload monitoring enabled; 6 targets `up=1` through the NetworkPolicies; `shop_orders_total` and request metrics per namespace |
| review optional (local and on OpenShift) | review scaled to 0: stars disappear, status "review: unreachable", an order is still placed; back to 1: stars return within ~10 s (`docs/screenshot-openshift-review-down.png`) |
| backup (shop) | RWO PVC on gp3, on-demand and scheduled jobs on the viewer's node, dumps visible with `oc rsh deploy/backup-viewer`, `pg_restore --list` shows table, data and index |
| demos from deploy.md | load balancing over 3 catalog pods, catalog 2.0.0 look, readiness fault through a rollout (stalls, shop keeps working) and at runtime (catalog red, 502, then green) |

**Not verified yet:** trace export to a real OpenTelemetry collector (the code
path only runs when `OTEL_EXPORTER_OTLP_ENDPOINT` is set).

### Things to know

* **web needs the backend names at start.** nginx resolves `catalog`, `cart` and `orders` when it starts and refuses to start if one does not resolve. On OpenShift the Services exist (same kustomization); a stand-alone `podman run` of web needs `--add-host catalog:…` (as `make check-images` does). Resolving at request time would need the cluster DNS IP in the nginx config, which differs per cluster.
* **Rootless podman on macOS cannot run UID 1000680000** (its user namespace maps only ~65 000 UIDs). Use the rootful connection of the podman machine: `make check-images PODMAN="podman --connection podman-machine-default-root"`.
* **Stock and carts live in memory, per pod.** Two catalog replicas count stock independently; two cart replicas do not share carts. That is deliberate – a lab topic.
* **The migration Job is immutable.** To rerun it with a new image: `oc delete job orders-migrate`, then `oc apply -k` again.
* **Starlette warns** that its test client prefers a newer `httpx2` package; `make test` hides that warning. Switching would add a dependency that is not on the approved list.
* **Schemas for `make validate`** come from the internet: ServiceMonitor from the datreeio CRDs catalog, Route from `melmorabity/openshift-json-schemas` (OpenShift 4.18). Set `KUBECONFORM_SCHEMAS` / `OPENSHIFT_SCHEMAS` for a mirror.
* **No git repository yet**, so images built now carry the revision `unknown`; with git, `make build` uses `git rev-parse --short HEAD`.
* **quay.io lists new tags with a delay**, and `podman search --list-tags` may even return a cached, empty list – that is why `make push` verifies by pulling the tag back instead.
