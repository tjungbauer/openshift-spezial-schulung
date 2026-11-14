# Lab 6 – Break it – and watch it heal (35 min)

The shop runs from your Git repository (Day 2 start). Now you break catalog on purpose – through
Git, the way a bad release would arrive – and watch what the probes, the Deployment and the
HorizontalPodAutoscaler do about it.

**You will learn**

- what the three probes ask – and what OpenShift does when each one says "no"
- that an unready Pod is taken out of the Service, not restarted
- how a wrong liveness probe restarts a perfectly healthy container
- how a startup probe protects a slow start – and a rollout protects the users
- how an HPA adds replicas under load – and why Git must not own the replica count then

**How to work through this lab**

- Run every command from the folder `lab-06/`. Your shop repository is `$SHOP_WORK`
  (`~/shop-gitops` from the Day 2 start); the commands write into it with `"$SHOP_WORK/…"`
  and `git -C "$SHOP_WORK"` – you never change directories.
- Every change to the shop is a **commit and push**, followed by a refresh of the Application.
- `files/` contains everything you copy into your repository, and two lab tools:
  `fault.sh` (switches a fault on in a catalog Pod) and `load.yaml` (a load generator).

## Before you start

The Day 2 start must be done: `shop-dev` is `Synced` and `Healthy`
(`labs/day2-start/README.md`).

```bash
export NS=user-01                       # your namespace – your Argo CD runs here
export SHOP_NS=$NS-shop                 # the shop runs here
export SHOP_WORK=~/shop-gitops          # your local copy of the shop repository
oc project $SHOP_NS
```

The command you will use after every push – Argo CD looks at Git now instead of in three
minutes:

```bash
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
```

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Your starting point | 3 min |
| 2 | Read the probes | 4 min |
| 3 | Unready, not dead | 8 min |
| 4 | A wrong liveness probe | 7 min |
| 5 | A slow start | 6 min |
| 6 | Scale on load | 7 min |

---

### 1 · Your starting point

**Goal:** the shop runs, Argo CD manages it, and you can reach it.

```bash
oc -n $NS get applications.argoproj.io shop-dev
oc get pods
ROUTE=$(oc get route web -o jsonpath='{.spec.host}')
echo https://$ROUTE
```

**Expected result:** `shop-dev` `Synced` / `Healthy`; five Pods `1/1 Running` (web, catalog,
cart, orders, review); the shop opens in the browser. Keep the browser tab open – you will see
catalog disappear and come back.

> **What to notice:** from now on you change nothing with `oc edit`, `oc scale` or `oc set`
> – self heal would undo it (lab 5). Changes go through Git.

**If it does not work**

- `shop-dev` not found – the Day 2 start is missing, or you are looking in the wrong namespace
  (`-n $NS`).
- `OutOfSync` / `Degraded` – open the Application in the Argo CD UI; the event list says why.

---

### 2 · Read the probes

**Goal:** know what each probe of catalog asks, how often, and what happens on "no".

```bash
oc get deployment catalog -o yaml | grep -A8 -E '^ +(startupProbe|readinessProbe|livenessProbe):'
```

**What happens:** the live Deployment – exactly what Argo CD applied from
`$SHOP_WORK/base/catalog/deployment.yaml`. Read path, `periodSeconds` and `failureThreshold`
of each probe.

**Expected result:**

| Probe | Question | On "no" (failureThreshold reached) |
|---|---|---|
| startup | has the app started? | after 60 s (30 x 2 s): restart. Until it succeeds, the other two do not run |
| readiness | can it serve right now? | out of the Service – **no** restart |
| liveness | is the process stuck? | restart of the container |

> **What to notice:** `/health/live` of the shop never checks other services – a restart does
> not fix a database that is down. `/health/ready` does check what catalog needs.

---

### 3 · Unready, not dead

**Goal:** make catalog unready and see who notices – the Service yes, the kubelet's restart no.

The fault switch needs an admin token in catalog – a patch in your dev overlay:

```bash
cat files/patch-catalog-lab.yaml
cp files/patch-catalog-lab.yaml "$SHOP_WORK/overlays/dev/"
printf 'patches:\n- path: patch-catalog-lab.yaml\n' >> "$SHOP_WORK/overlays/dev/kustomization.yaml"
oc kustomize "$SHOP_WORK/overlays/dev" | grep -A1 ADMIN_TOKEN
git -C "$SHOP_WORK" add .
git -C "$SHOP_WORK" commit -m "dev: admin token for catalog (lab 6)"
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc rollout status deployment/catalog --timeout=180s
```

The `printf` appends a `patches:` list to the end of the dev kustomization – the shop's dev
overlay has none yet.

Now the fault – catalog answers `/health/ready` with 503 from now on:

```bash
cat files/fault.sh
./files/fault.sh '{"fail_ready": true}'
oc get pods -l app.kubernetes.io/name=catalog -w          # READY 0/1 after ~10 s – Ctrl-C
oc get endpointslice -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}  ready={.conditions.ready}{"\n"}{end}'
oc get events --field-selector reason=Unhealthy | tail -3
```

Reload the shop in the browser. Then switch the fault off again:

```bash
./files/fault.sh '{"fail_ready": false}'
oc get pods -l app.kubernetes.io/name=catalog -w          # back to 1/1 – Ctrl-C
```

**What happens:** `fault.sh` runs a few lines of Python **inside** the catalog container
(`oc exec`) and calls `POST /admin/fault` on `localhost` with the container's own token – no
Route and no NetworkPolicy in the way, and it works while the Pod is unready. The readiness
probe fails twice (2 x 5 s), the kubelet sets the Pod to not ready, the EndpointSlice marks it
`ready=false` – the Service stops sending traffic.

**Expected result:** `READY 0/1`, `RESTARTS 0`; the EndpointSlice says `ready=false`; the events
show `Readiness probe failed: HTTP probe failed with statuscode: 503`. The shop shows that catalog
is unreachable – with **one** replica, unready means: nobody serves. After switching off: `1/1`,
the products are back.

> **What to notice:** no restart – readiness only decides about traffic. With two replicas the
> users would not have noticed anything (demo 13). The Application stays `Synced`: nothing
> in Git changed.

**If it does not work**

- `fault.sh` prints `admin endpoint disabled (ADMIN_TOKEN not set)` – the new Pod with the token
  is not running yet: `oc rollout status deployment/catalog`, then again.
- `exec: "python3.12": executable file not found` – catalog runs an unexpected image; ask the
  trainer.
- `printf` was run twice – `patches:` is twice in the kustomization; `oc kustomize` fails. Remove
  one block in `"$SHOP_WORK/overlays/dev/kustomization.yaml"`.

---

### 4 · A wrong liveness probe

**Goal:** see what a small mistake in the liveness probe does to a healthy application.

The "new release": the same patch, plus a typo in the liveness path (`/health/livez`):

```bash
diff files/patch-catalog-lab.yaml files/patch-catalog-typo.yaml
cp files/patch-catalog-typo.yaml "$SHOP_WORK/overlays/dev/patch-catalog-lab.yaml"
git -C "$SHOP_WORK" commit -am "dev: new liveness path"
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc get pods -l app.kubernetes.io/name=catalog -w          # watch RESTARTS for ~2 minutes – Ctrl-C
oc get events --field-selector reason=Unhealthy | grep -i liveness | tail -3
oc get events --field-selector reason=Killing | tail -3
```

**What happens:** the rollout succeeds – readiness is fine. 30 s later (3 x 10 s) the liveness
probe has failed three times with 404, the kubelet kills the container and starts it again. The
startup probe runs first, then liveness fails again …

**Expected result:** `RESTARTS` goes up every ~40 s; after a few restarts the status shows
`CrashLoopBackOff` between the attempts. Events: `Liveness probe failed: HTTP probe failed with
statuscode: 404` and `Container catalog failed liveness probe, will be restarted`. The shop loses
catalog for a few seconds at every restart.

Roll back – the GitOps way:

```bash
git -C "$SHOP_WORK" revert --no-edit HEAD
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc rollout status deployment/catalog --timeout=180s
oc get pods -l app.kubernetes.io/name=catalog            # a new Pod, RESTARTS 0
```

> **What to notice:** nothing was wrong with the application – only with the question the
> kubelet asked. A liveness probe that fails for the wrong reason turns a healthy app into a
> restart loop. Keep it simple; never check dependencies in it.

---

### 5 · A slow start

**Goal:** see how the startup probe and the rolling update handle a release that needs 40 s to
start.

```bash
diff files/patch-catalog-lab.yaml files/patch-catalog-slow.yaml
cp files/patch-catalog-slow.yaml "$SHOP_WORK/overlays/dev/patch-catalog-lab.yaml"
git -C "$SHOP_WORK" commit -am "dev: catalog starts slowly"
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc get pods -l app.kubernetes.io/name=catalog -w          # ~1 minute – Ctrl-C
oc get events --field-selector reason=Unhealthy | grep -i startup | tail -3
```

Reload the shop during the minute.

**What happens:** `FAULT_STARTUP_DELAY_S=40` makes `/health/started` answer 503 for 40 s. The
startup probe allows 60 s (30 x 2 s), so nothing is killed; readiness and liveness wait. The
rolling update keeps the old Pod until the new one is ready.

**Expected result:** two catalog Pods for about 40 s – the old one `1/1`, the new one `0/1`
`Running`, `RESTARTS 0`; then the old one terminates. Events: `Startup probe failed … 503`. The
shop works the whole time.

Undo the slow start:

```bash
git -C "$SHOP_WORK" revert --no-edit HEAD
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
```

> **What to notice:** the startup probe is the budget for a slow start – without it, a liveness
> probe that asks too early kills the app before it is up (demo 13). And readiness gates the
> rollout: the old version serves until the new one is ready.

---

### 6 · Scale on load

**Goal:** let a HorizontalPodAutoscaler run catalog with 2–6 replicas at 60 % of its CPU request
– and take the replica count out of Git.

```bash
cat files/hpa-catalog.yaml
cat files/kustomization-dev-hpa.yaml
cp files/hpa-catalog.yaml "$SHOP_WORK/overlays/dev/"
cp files/kustomization-dev-hpa.yaml "$SHOP_WORK/overlays/dev/kustomization.yaml"
oc kustomize "$SHOP_WORK/overlays/dev" | grep -E '^kind: HorizontalPodAutoscaler|replicas:'
git -C "$SHOP_WORK" add .
git -C "$SHOP_WORK" commit -m "dev: HPA for catalog, replicas no longer in Git"
git -C "$SHOP_WORK" push
oc -n $NS annotate applications.argoproj.io shop-dev argocd.argoproj.io/refresh=normal --overwrite
oc get hpa catalog -w                                     # REPLICAS 2 – Ctrl-C
```

The load generator is a lab tool, not part of the shop – it does **not** go to Git:

```bash
cat files/load.yaml
oc apply -f files/load.yaml
oc get hpa catalog -w                                     # 2-3 minutes – Ctrl-C
oc get pods -l app.kubernetes.io/name=catalog
oc adm top pods -l app.kubernetes.io/name=catalog
```

Stop the load:

```bash
oc delete -f files/load.yaml
```

**What happens:** the new kustomization adds `hpa-catalog.yaml` and a JSON patch that **removes**
`spec.replicas` from catalog: Git no longer says how many replicas there are, the HPA does. The
load Pods (2 x 4 curl loops) call catalog directly – the second object in `load.yaml` is a
NetworkPolicy that lets them in. CPU utilisation = usage / request (50m); above 60 % the HPA
adds replicas.

**Expected result:** the HPA starts at 2 replicas, `TARGETS` climbs above `60%`, `REPLICAS` goes
up to 4–6 within a few minutes; `shop-dev` stays `Synced`. After the load stops, the HPA scales
back to 2 – after about five minutes (scale-down stabilisation window).

> **What to notice:** with `replicas: 1` still in Git, self heal and the HPA would fight –
> one sets 1, the other 2. Either remove the field from Git (as here) or ignore it in the
> Application (`ignoreDifferences` on `/spec/replicas`, module 05 quiz).

**If it does not work**

- `TARGETS <unknown>/60%` – metrics need a minute; `oc describe hpa catalog` shows the reason.
- The HPA stays at 2 – the load Pods cannot reach catalog: `oc get networkpolicy
  allow-load-to-catalog`, `oc logs deploy/load` (empty is fine; errors are not).

---

## Done early? Bonus

- **Graceful shutdown under load:** keep the load running, open a second terminal with
  `ROUTE=$(oc get route web -o jsonpath='{.spec.host}')`, then
  `while true; do curl -s -o /dev/null -w '%{http_code} ' https://$ROUTE/api/catalog/products; done`
  and trigger a rollout through Git (any change in `patch-catalog-lab.yaml`). Any non-200? Then
  add a `lifecycle.preStop` with `sleep 5` to the catalog container in the patch – and compare.
- **Two replicas, one unready:** with the HPA at 2+ replicas, run task 3 again with a Pod name:
  `./files/fault.sh '{"fail_ready": true}' <pod>` – does the shop notice?

## Cleanup

Nothing to clean up – lab 7 continues with this state. If you want catalog without the admin
token again: remove `patch-catalog-lab.yaml` from the `patches:` list, commit, push.
