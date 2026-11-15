# Lab 7 – Trainer: walkthrough, solution and checks

The scripts live in `lab-07/trainer/` so students do not find them right away (the student
instructions are in [../README.md](../README.md)). They run the commands of the student README
from `lab-07/`, with the same variables (`$NS`, `$SHOP_NS`, `$SHOP_WORK`). The Day 2 start
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
`oc adm top pods -n user-01-shop` must show values (needed for the HPA in bonus task 5b).

## Walkthrough, solution and checks

Both scripts default to the namespace `lab`: they create it with its own Argo CD instance, the
shop runs in `lab-shop`, cleanup deletes both. Other namespaces (e.g. `user-01`) are only used –
cleanup removes just the load generator there, because lab 8 continues with that state.

Needs: `oc` (logged in, cluster-admin for the default namespace), `git`, and a Git repository
**the trainer owns** – the scripts **force-push** to its branch `main`:

```bash
export GIT_REPO_URL=https://git.acme.example/trainer/shop-gitops.git
export GIT_USERNAME=trainer
printf 'Git token: '; read -rs GIT_TOKEN; echo; export GIT_TOKEN
```

Run from `lab-07/`:

```bash
./trainer/lab-07-walkthrough.sh               # all tasks, ENTER runs each command (asks for 5a + 5b)
./trainer/lab-07-walkthrough.sh 4             # a single task (earlier state is created quietly)
./trainer/lab-07-walkthrough.sh slow          # bonus task 5a: a slow start
./trainer/lab-07-walkthrough.sh hpa           # bonus task 5b: scale on load
./trainer/lab-07-walkthrough.sh bonus         # two replicas, one unready
./trainer/lab-07-walkthrough.sh cleanup

./trainer/lab-07-solve.sh                     # all tasks incl. 5a + 5b, then checks
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

How the lab works: the students switch auto-sync off and on in the **Argo CD UI** (they have no
rights on Application objects). The scripts do the same with `oc patch` on the Application – the
trainer has those rights. Task 1 removes `spec.syncPolicy.automated` from `shop-dev`,
tasks 3–5 change catalog with `oc set env`, `oc patch` and
`oc rollout undo`. Task 6 commits the result (admin token, HPA, no `spec.replicas`) and switches
auto-sync on again – that is the state lab 8 expects. A single task (`… 3`) switches auto-sync off
quietly; run task 6 afterwards to get the student state back.

Timing: tasks 4 and 5 wait for the cluster (restarts, a 40 s start, the HPA) – the
full walkthrough takes about 20 minutes.

### Files

| File | Purpose |
|------|---------|
| `files/patch-catalog-lab.yaml` | catalog with `ADMIN_TOKEN` – into Git in task 6 |
| `files/hpa-catalog.yaml` | the HPA – applied with `oc` in task 5b, into Git in task 6 |
| `files/kustomization-dev-hpa.yaml` | the dev kustomization with the token patch, the HPA and without `spec.replicas` for catalog (task 6) |
| `files/fault.sh` | `POST /admin/fault` inside a catalog Pod via `oc exec` – works while unready |
| `files/load.yaml` | load generator + NetworkPolicy that lets it reach catalog (not in Git) |
| `trainer/lab-07-lib.sh` | tasks, checks and cleanup shared by both scripts |

`files/kustomization-dev-hpa.yaml` is the shop's `deploy/overlays/dev/kustomization.yaml` plus
the lab additions – if the shop's dev overlay changes, update this file too.
