# Helm chart `shop`

The ACME shop as a Helm chart – the same objects as the Kustomize overlays in
`deploy/overlays/dev` and `deploy/overlays/prod` (checked object by object), plus
a `helm test`, a migration hook, a values schema and NOTES.

| Values file | Like | Orders data |
|---|---|---|
| `values.yaml` (defaults) | base | SQLite on an `emptyDir` |
| `values-dev.yaml` | `overlays/dev` | SQLite on the PVC `orders-data` |
| `values-prod.yaml` | `overlays/prod` | PostgreSQL StatefulSet + backups |

Resource names are fixed (`web`, `catalog`, `cart`, `orders`, `review`, `postgres`):
web's nginx finds the backends by these Service names – **one shop per namespace**.
Do not install the chart into a namespace that already runs the Kustomize version
(Helm refuses to take over objects it does not own).

## Install, upgrade, test (from `revoked/shop`)

```bash
export NS=shop-dev
oc project $NS
helm lint deploy/helm/shop -f deploy/helm/shop/values-dev.yaml
helm upgrade --install shop deploy/helm/shop -n $NS \
  -f deploy/helm/shop/values-dev.yaml --wait --timeout 5m
helm test shop -n $NS
helm history shop -n $NS
```

Prod variant (PostgreSQL, migration hook, backups):

```bash
helm upgrade --install shop deploy/helm/shop -n shop \
  -f deploy/helm/shop/values-prod.yaml --wait --timeout 5m
```

Render without a cluster – the Route is always rendered, ServiceMonitors only when the
API is known:

```bash
helm template shop deploy/helm/shop -f deploy/helm/shop/values-prod.yaml \
  --api-versions monitoring.coreos.com/v1 | oc apply --dry-run=server -f -
```

## What the chart shows

| Feature | Where |
|---|---|
| labels, image name, probes, security context as named templates | `templates/_helpers.tpl` |
| `fail` for combinations that do not work | `shop.validate` in `_helpers.tpl` |
| `required` for the image tag and the DB password | `_helpers.tpl`, `postgres.yaml` |
| `range` + `$` for Services and ServiceMonitors | `services.yaml`, `servicemonitors.yaml` |
| `.Capabilities.APIVersions.Has` | `servicemonitors.yaml` |
| checksum annotation – ConfigMap change rolls the Pods | `deployment-catalog.yaml`, `deployment-orders.yaml` |
| `post-install,post-upgrade` hook with `before-hook-creation` | `job-migrate.yaml` |
| `helm test` (plus the NetworkPolicy it needs) | `tests/test-api.yaml`, `networkpolicies.yaml` |
| `.Release` / `.Chart` in NOTES | `templates/NOTES.txt` |
| values schema | `values.schema.json` |

## Good to know

- `helm uninstall` keeps the PVC `data-postgres-0` – it was created by the
  StatefulSet, not by Helm. Delete it by hand: `oc delete pvc data-postgres-0`.
- `orders.persistence.enabled` and `postgresql.enabled` are alternatives;
  `backup.enabled` needs `postgresql.enabled` – the chart stops with a message otherwise.
- Same image tag pushed again? `imagePullPolicy: Always` fetches it, but nothing
  rolls out by itself: `oc rollout restart deployment -l app.kubernetes.io/part-of=shop`.
