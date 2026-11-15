# Lab 7 – Break it – and watch it heal (35 min)

The shop runs from your Git repository (Day 2 start). Now you break catalog on purpose and watch  
what the probes, the Deployment and the HorizontalPodAutoscaler do about it. To keep it quick,  
you switch off the auto-sync of your Application and change catalog **directly** with `oc` – if you want to keep it in GitOps  
keep auto-sync and push every change into git

**You will learn**

- what the three probes ask – and what OpenShift does when each one says "no"
- that an unready Pod is taken out of the Service, not restarted
- how a wrong liveness probe restarts a perfectly healthy container
- why `oc` changes only "stick" while auto-sync is off – and how to get back to Git
- BONUS: how a startup probe protects a slow start – and a rollout protects the users
- BONUS: how an HPA adds replicas under load – and why Git must not own the replica count then

**How to work through this lab**

- Run every command from the folder `lab-07/`. Your shop repository is `$SHOP_WORK`
(`~/shop-gitops` from the Day 2 start); the commands write into it with `"$SHOP_WORK/…"`
and `git -C "$SHOP_WORK"` – you never change directories.
- Tasks 1–5 change catalog with `oc` – **auto-sync is off**. Task 6 puts the result into Git
and switches auto-sync on again. Do task 6 in any case – lab 8 builds on it.
- Auto-sync is switched off and on in the **Argo CD UI** (tasks 1 and 6) – keep it open in a
browser tab.
- `files/` contains the files for task 6, and two lab tools: `fault.sh` (switches a fault on in
a catalog Pod) and `load.yaml` (a load generator).

## Before you start

The Day 2 start must be done: `shop-dev` is `Synced` and `Healthy`
(`labs/day2-start/README.md`).

```bash
export NS=sbx-wsXX                      # your namespace – the shop runs here
export SHOP_WORK=~/shop-gitops          # your local copy of the shop repository
oc project $NS
```

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Your starting point – auto-sync off | 5 min |
| 2 | Read the probes | 4 min |
| 3 | Unready, not dead | 7 min |
| 4 | A wrong liveness probe | 7 min |
| 5a | Bonus: a slow start | 5 min |
| 5b | Bonus: scale on load | 7 min |
| 6 | Back to Git – auto-sync on | 5 min |

---

### 1 · Your starting point – auto-sync off

**Goal:** the shop runs, Argo CD manages it – and from now on, Argo CD only watches.

```bash
oc get pods
ROUTE=$(oc get route web -o jsonpath='{.spec.host}')
echo https://$ROUTE
```

Keep the browser tab open – you will see catalog disappear and come back. Now switch off the
auto-sync – in the **Argo CD UI**, with your Application from the Day 2 start:

1. Open the Application tile and click **APP DETAILS**.
2. Under **SYNC POLICY**, click **DISABLE AUTO-SYNC** and confirm.
3. Close the details – the Application header now shows that auto sync is not enabled.

**Expected result:** the Application `Synced` / `Healthy` before the change; five Pods
`1/1 Running` (web, catalog, cart, orders, review); the shop opens in the browser. After the
change, **SYNC POLICY** offers **ENABLE AUTO-SYNC** – auto-sync is off.

> **What to notice:** without auto-sync there is no self heal: `oc set`, `oc patch` and
> `oc rollout undo` now stay as they are. Argo CD still compares Git with the cluster and shows
> **OutOfSync** – it just does not act. That is fine for experiments, never for a real
> environment.

**If it does not work**

- You do not see your Application – the Day 2 start is missing, or the filter of the
Applications page hides it (clear the filters, search for your namespace).
- **DISABLE AUTO-SYNC** is greyed out or ends with "permission denied" – your Argo CD role does
not allow changing the Application; ask the trainer.
- `OutOfSync` / `Degraded` at the start – open the Application; the event list says why.

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

The fault switch needs an admin token in catalog:

```bash
oc set env deployment/catalog ADMIN_TOKEN=lab-token
oc rollout status deployment/catalog --timeout=180s
```

Now the fault – catalog answers `/health/ready` with 503 from now on:

```bash
cat files/fault.sh
./files/fault.sh '{"fail_ready": true}'
oc get pods -l app.kubernetes.io/name=catalog -w          # READY 0/1 after ~10 s – Ctrl-C
```

Check the endpoints and events:

```bash
oc get endpointslice -l kubernetes.io/service-name=catalog \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}  ready={.conditions.ready}{"\n"}{end}'
oc get events --field-selector reason=Unhealthy | tail -3
```

Reload the shop in the browser. Then switch the fault off again:

```bash
./files/fault.sh '{"fail_ready": false}'
oc get pods -l app.kubernetes.io/name=catalog -w          # back to 1/1 – Ctrl-C
```

**What happens:** `oc set env` changes the Pod template – a rollout starts a new catalog Pod
with `ADMIN_TOKEN`. `fault.sh` runs a few lines of Python **inside** the catalog container
(`oc exec`) and calls `POST /admin/fault` on `localhost` with the container's own token – no
Route and no NetworkPolicy in the way, and it works while the Pod is unready. The readiness
probe fails twice (2 x 5 s), the kubelet sets the Pod to not ready, the EndpointSlice marks it
`ready=false` – the Service stops sending traffic.

**Expected result:** `READY 0/1`, `RESTARTS 0`; the EndpointSlice says `ready=false`; the events
show `Readiness probe failed: HTTP probe failed with statuscode: 503`. The shop shows that catalog
is unreachable – with **one** replica, unready means: nobody serves. After switching off: `1/1`,
the products are back.

> **What to notice:** no restart – readiness only decides about traffic. With two replicas the
> users would not have noticed anything (demo 14).

**If it does not work**

- `fault.sh` prints `admin endpoint disabled (ADMIN_TOKEN not set)` – the new Pod with the token
is not running yet: `oc rollout status deployment/catalog`, then again.
- The token disappears again after a minute – auto-sync is still on (task 1).
- `exec: "python3.12": executable file not found` – catalog runs an unexpected image; ask the
trainer.

---

### 4 · A wrong liveness probe

**Goal:** see what a small mistake in the liveness probe does to a healthy application.

The "new release": a typo in the liveness path (`/health/livez`):

```bash
oc patch deployment catalog -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"catalog","livenessProbe":{"httpGet":{"path":"/health/livez"}}}]}}}}'
oc get pods -l app.kubernetes.io/name=catalog -w          # watch RESTARTS for ~2 minutes – Ctrl-C
```

Verify the events:

```bash
oc get events --field-selector reason=Unhealthy | grep -i liveness | tail -3
oc get events --field-selector reason=Killing | tail -3
```

In the Argo CD UI, look at your Application.

**What happens:** the patch merges into the catalog container (by its name) and changes only
the path. The rollout succeeds – readiness is fine. 30 s later (3 x 10 s) the liveness probe has
failed three times with 404, the kubelet kills the container and starts it again. The startup
probe runs first, then liveness fails again …

**Expected result:** `RESTARTS` goes up every ~40 s; after a few restarts the status shows
`CrashLoopBackOff` between the attempts. Events: `Liveness probe failed: HTTP probe failed with statuscode: 404` and `Container catalog failed liveness probe, will be restarted`. The shop loses
catalog for a few seconds at every restart. In the Argo CD UI the Application is **OutOfSync**
– the path differs from Git.

Roll back – here with the Deployment's own history:

```bash
oc rollout history deployment/catalog
oc rollout undo deployment/catalog
oc rollout status deployment/catalog --timeout=180s
oc get pods -l app.kubernetes.io/name=catalog            # a new Pod, RESTARTS 0
```

> **What to notice:** nothing was wrong with the application – only with the question the
> kubelet asked. A liveness probe that fails for the wrong reason turns a healthy app into a
> restart loop. Keep it simple; never check dependencies in it. `oc rollout undo` goes back to
> the previous Pod template – with auto-sync on, the GitOps way is `git revert` instead.

---

### 5 · Bonus – if you have time (auto-sync is still off)

#### 5a · A slow start

**Goal:** see how the startup probe and the rolling update handle a release that needs 40 s to
start.

```bash
oc set env deployment/catalog FAULT_STARTUP_DELAY_S=40
oc get pods -l app.kubernetes.io/name=catalog -w          # ~1 minute – Ctrl-C
oc get events --field-selector reason=Unhealthy | grep -i startup | tail -3
```

Reload the shop during the minute. Then undo the slow start:

```bash
oc rollout undo deployment/catalog
oc rollout status deployment/catalog --timeout=180s
```

**What happens:** `FAULT_STARTUP_DELAY_S=40` makes `/health/started` answer 503 for 40 s. The
startup probe allows 60 s (30 x 2 s), so nothing is killed; readiness and liveness wait. The
rolling update keeps the old Pod until the new one is ready.

**Expected result:** two catalog Pods for about 40 s – the old one `1/1`, the new one `0/1`
`Running`, `RESTARTS 0`; then the old one terminates. Events: `Startup probe failed … 503`. The
shop works the whole time.

> **What to notice:** the startup probe is the budget for a slow start – without it, a liveness
> probe that asks too early kills the app before it is up (demo 14). And readiness gates the
> rollout: the old version serves until the new one is ready.

#### 5b · Scale on load

**Goal:** let a HorizontalPodAutoscaler run catalog with 2–6 replicas at 60 % of its CPU request.

```bash
cat files/hpa-catalog.yaml
oc apply -f files/hpa-catalog.yaml
oc get hpa catalog -w                                     # REPLICAS 2 – Ctrl-C
```

The load generator is a lab tool, not part of the shop:

```bash
cat files/load.yaml
oc apply -f files/load.yaml
oc get hpa catalog -w                                     # 2-3 minutes – Ctrl-C
oc get pods -l app.kubernetes.io/name=catalog
oc adm top pods -l app.kubernetes.io/name=catalog
oc delete -f files/load.yaml
```

**What happens:** the load Pods (2 x 4 curl loops) call catalog directly – the second object in
`load.yaml` is a NetworkPolicy that lets them in. CPU utilisation = usage / request (50m); above
60 % the HPA adds replicas.

**Expected result:** the HPA starts at 2 replicas, `TARGETS` climbs above `60%`, `REPLICAS` goes
up to 4–6 within a few minutes. After the load stops, the HPA scales back to 2 – after about
five minutes (scale-down stabilisation window).

> **What to notice:** Git still says `replicas: 1` for catalog. With auto-sync on, self heal and
> the HPA would fight – one sets 1, the other 2. That is why task 6 removes the field from Git.

**If it does not work**

- `TARGETS <unknown>/60%` – metrics need a minute; `oc describe hpa catalog` shows the reason.
- The HPA stays at 2 – the load Pods cannot reach catalog: `oc get networkpolicy allow-load-to-catalog`, `oc logs deploy/load` (empty is fine; errors are not).

---

### 6 · OPTIONAL: Back to Git – auto-sync on

**Goal:** what you tried with `oc` goes into Git – the admin token and an HPA for catalog
without a replica count in Git – and Argo CD takes over again. Everybody does this task.

```bash
oc delete -f files/load.yaml --ignore-not-found
cat files/patch-catalog-lab.yaml
diff "$SHOP_WORK/overlays/dev/kustomization.yaml" files/kustomization-dev-hpa.yaml
cp files/patch-catalog-lab.yaml files/hpa-catalog.yaml "$SHOP_WORK/overlays/dev/"
cp files/kustomization-dev-hpa.yaml "$SHOP_WORK/overlays/dev/kustomization.yaml"
oc kustomize "$SHOP_WORK/overlays/dev" | grep -E 'ADMIN_TOKEN|^kind: HorizontalPodAutoscaler'
git -C "$SHOP_WORK" add .
git -C "$SHOP_WORK" commit -m "dev: admin token and HPA for catalog (lab 7)"
git -C "$SHOP_WORK" push
```

Auto-sync on again – in the **Argo CD UI**, your Application:

1. **APP DETAILS** › **SYNC POLICY** › **ENABLE AUTO-SYNC**, confirm.
2. In the same place switch on **PRUNE RESOURCES** and **SELF HEAL** – as at the Day 2 start.
3. Close the details and click **REFRESH** – Argo CD looks at Git now instead of in three

   minutes. Wait for `Synced` / `Healthy`.

Then check the result:

```bash
oc get hpa catalog
oc set env deployment/catalog --list | grep -E 'ADMIN_TOKEN|FAULT'
```

**What happens:** the new kustomization adds `hpa-catalog.yaml`, the admin token patch and a
JSON patch that **removes** `spec.replicas` from catalog: Git no longer says how many replicas
there are, the HPA does. With auto-sync back, Argo CD syncs the commit and self heal is on
again.

**Expected result:** the Application `Synced` / `Healthy` with auto-sync, prune and self heal on;
the HPA `catalog` with `MINPODS 2`,
`MAXPODS 6` and 2 replicas; `ADMIN_TOKEN=lab-token`, no `FAULT_STARTUP_DELAY_S`.

> **What to notice:** Argo CD only compares the fields that are in Git. A value you added with
> `oc` that Git does not know about – an extra environment variable – can survive the sync
> unnoticed. That is why the last command checks for leftovers.

**If it does not work**

- `FAULT_STARTUP_DELAY_S=40` is still listed – 5a was not undone:
`oc set env deployment/catalog FAULT_STARTUP_DELAY_S-`.
- `OutOfSync` stays – press **REFRESH** again; `oc kustomize "$SHOP_WORK/overlays/dev"` must
work without errors. **APP DETAILS** shows whether auto-sync is really on.
- `diff` shows more than the lab lines – your dev kustomization was changed before; keep your
changes and add only the lines of `files/kustomization-dev-hpa.yaml`.

---

## Cleanup

Nothing to clean up – lab 8 continues with this state (admin token, HPA, auto-sync on). Check
that the load generator is gone: `oc get deployment load` → `NotFound`.
