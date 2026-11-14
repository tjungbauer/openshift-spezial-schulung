# Lab 7 – Trainer: walkthrough, solution and checks

The scripts live in `lab-07/trainer/` so students do not find them right away (the student
instructions are in [../README.md](../README.md)). They run the commands of the student README
from `lab-07/`, with the same variables (`$NS`, `$SHOP_NS`, `$SHOP_WORK`). What lab 7 builds on
is done quietly first if it is missing: the Day 2 start (repository, Secret, Application
`shop-dev`) and the end state of lab 6 (admin token for catalog, HPA, no replica count in Git).

## Before the training

Lab 7 needs nothing new on the cluster – the same as lab 6:

- user workload monitoring enabled (`enableUserWorkload: true` in `cluster-monitoring-config`);
- the students can open **Observe › Metrics** and **Observe › Alerting** for their shop
  namespace (namespace admins can);
- **no** logging stack needed: task 6 uses `oc logs`. With LokiStack and the Cluster Logging
  Operator installed, Observe › Logs works as well – the README mentions it.

## Walkthrough, solution and checks

Both scripts default to the namespace `lab`: they create it with its own Argo CD instance, the
shop runs in `lab-shop`, cleanup deletes both. Other namespaces (e.g. `user-01`) are only used –
cleanup removes just the traffic generator there, because lab 8 continues with that state.

Needs: `oc` (logged in, cluster-admin for the default namespace), `git`, and a Git repository
**the trainer owns** – the scripts **force-push** to its branch `main`:

```bash
export GIT_REPO_URL=https://git.acme.example/trainer/shop-gitops.git
export GIT_USERNAME=trainer
printf 'Git token: '; read -rs GIT_TOKEN; echo; export GIT_TOKEN
```

Run from `lab-07/`:

```bash
./trainer/lab-07-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-07-walkthrough.sh 5             # a single task (earlier state is created quietly)
./trainer/lab-07-walkthrough.sh bonus         # the slow alert (CatalogSlow)
./trainer/lab-07-walkthrough.sh cleanup

./trainer/lab-07-solve.sh                     # all tasks + README cleanup + checks
./trainer/lab-07-solve.sh check               # PASS / FAIL, exit code = number of failures
LAB_NS=user-01 ./trainer/lab-07-solve.sh check   # check a student (no Git needed)
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace with Argo CD (default: `lab`); the shop runs in `NAME-shop` |
| `GIT_REPO_URL` | HTTPS URL of the trainer's shop repository – force-pushed |
| `GIT_USERNAME`, `GIT_TOKEN` | credentials for `git push` and the Argo CD repository Secret |
| `WORK_DIR=PATH` | where the repository is built (default `${TMPDIR:-/tmp}/lab-07-<namespace>`) |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |

**Query results and the alert state:** the students run the queries in the console. The scripts
print each query and – with `curl` and a cluster-admin login – also its result for the lab
namespace, read from the Thanos Querier Route (`openshift-monitoring/thanos-querier`). The same
way they wait until `CatalogErrorRateHigh` is firing and check that it has resolved. Without that
access they print a note, wait a fixed time (task 5: 180 s) and skip the alert check.

Timing: task 5 waits for the alert (about 2–3 minutes), the bonus up to 4 minutes – the full
walkthrough takes about 15 minutes.

### Files

| File | Purpose |
|------|---------|
| `files/traffic.yaml` | ~5 requests/s through web + NetworkPolicy that lets it reach web (not in Git) |
| `files/prometheusrule-catalog.yaml` | `CatalogErrorRateHigh` (5xx > 5 % for 1 m), `CatalogSlow` (p95 > 500 ms for 2 m) |
| `files/kustomization-dev-alert.yaml` | lab 6's `kustomization-dev-hpa.yaml` plus the PrometheusRule (task 4) |
| `files/fault.sh` | `POST /admin/fault` in **every** catalog Pod via `oc exec` (lab 6's switched one) |
| `trainer/lab-07-lib.sh` | tasks, checks and cleanup shared by both scripts |

`files/kustomization-dev-alert.yaml` is lab 6's `files/kustomization-dev-hpa.yaml` plus one
resource line – if the shop's dev overlay or lab 6 changes, update this file too.

### Things students run into

- **`up` shows nothing** – the namespace selector in Observe › Metrics is still on another
  project.
- **The alert does not fire** – no traffic (`traffic` deleted too early) or the fault was set on
  one Pod only (`fault.sh JSON POD`): with two Pods the error ratio is halved.
- **`oc logs -l` shows only 10 lines per Pod** – that is the default with a selector; the
  README uses `--tail=-1`.
- **The 503 lines have `"level": "info"`** – on purpose: the shop logs every request line at
  info. Filter on `status`.
