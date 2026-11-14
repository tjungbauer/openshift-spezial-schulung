# Lab 6 – Trainer: walkthrough, solution and checks

The scripts live in `lab-06/trainer/` so students do not find them right away (the student
instructions are in [../README.md](../README.md)). They run the commands of the student README
from `lab-06/`, with the same variables (`$NS`, `$SHOP_NS`, `$SHOP_WORK`). The Day 2 start
(`labs/day2-start`) is done quietly first if it is missing: the shop's deployment files into the
Git repository, the repository Secret, the Application `shop-dev`.

## Before the training

Per student, as cluster-admin – in this order:

```bash
./labs/lab-05/trainer/lab-05-setup.sh user-01 user-02          # Argo CD in user-NN (Day 1)
./labs/day2-start/trainer/day2-setup.sh user-01 user-02        # user-NN-shop, managed by it
```

Check one student before Day 2: the Application `shop-dev` must be able to create the
ServiceMonitors in `user-01-shop` (user workload monitoring enabled on the cluster), and
`oc adm top pods -n user-01-shop` must show values (needed for the HPA in task 6).

## Walkthrough, solution and checks

Both scripts default to the namespace `lab`: they create it with its own Argo CD instance, the
shop runs in `lab-shop`, cleanup deletes both. Other namespaces (e.g. `user-01`) are only used –
cleanup removes just the load generator there, because lab 7 continues with that state.

Needs: `oc` (logged in, cluster-admin for the default namespace), `git`, and a Git repository
**the trainer owns** – the scripts **force-push** to its branch `main`:

```bash
export GIT_REPO_URL=https://git.acme.example/trainer/shop-gitops.git
export GIT_USERNAME=trainer
printf 'Git token: '; read -rs GIT_TOKEN; echo; export GIT_TOKEN
```

Run from `lab-06/`:

```bash
./trainer/lab-06-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-06-walkthrough.sh 4             # a single task (earlier state is created quietly)
./trainer/lab-06-walkthrough.sh bonus         # two replicas, one unready
./trainer/lab-06-walkthrough.sh cleanup

./trainer/lab-06-solve.sh                     # all tasks + checks
./trainer/lab-06-solve.sh check               # PASS / FAIL, exit code = number of failures
LAB_NS=user-01 ./trainer/lab-06-solve.sh check   # check a student (no Git needed)
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace with Argo CD (default: `lab`); the shop runs in `NAME-shop` |
| `GIT_REPO_URL` | HTTPS URL of the trainer's shop repository – force-pushed |
| `GIT_USERNAME`, `GIT_TOKEN` | credentials for `git push` and the Argo CD repository Secret |
| `WORK_DIR=PATH` | where the repository is built (default `${TMPDIR:-/tmp}/lab-06-<namespace>`) |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |

Timing: tasks 4–6 wait for the cluster (restarts, a 40 s start, the HPA) – the full walkthrough
takes about 20 minutes.

### Files

| File | Purpose |
|------|---------|
| `files/patch-catalog-lab.yaml` | catalog with `ADMIN_TOKEN` (task 3) |
| `files/patch-catalog-typo.yaml` | the same plus liveness path `/health/livez` (task 4) |
| `files/patch-catalog-slow.yaml` | the same plus `FAULT_STARTUP_DELAY_S=40` (task 5) |
| `files/hpa-catalog.yaml`, `files/kustomization-dev-hpa.yaml` | the HPA and the dev kustomization without `spec.replicas` for catalog (task 6) |
| `files/fault.sh` | `POST /admin/fault` inside a catalog Pod via `oc exec` – works while unready |
| `files/load.yaml` | load generator + NetworkPolicy that lets it reach catalog (not in Git) |
| `trainer/lab-06-lib.sh` | tasks, checks and cleanup shared by both scripts |

`files/kustomization-dev-hpa.yaml` is the shop's `deploy/overlays/dev/kustomization.yaml` plus
the lab additions – if the shop's dev overlay changes, update this file too.
