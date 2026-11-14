# Lab 2 – Trainer: walkthrough, solution and checks

The scripts live in `lab-02/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They work on the
lab files in `lab-02/` and can be started from any directory.

Both scripts use the shared demo library (`demos/lib`) and default to the
namespace `lab` (created if missing). Cleanup removes the shop, PostgreSQL, the
backup objects and **both PVCs** (`data-postgres-0`, `backups`) – never the project.

## Why the lab looks like this

Writing five Deployments by hand would eat the 35 minutes and teach nothing new
after Lab 0. So the students deploy the shop with **one** command and spend their
time on what module 02 is about:

| Task | Module 02 topic |
|---|---|
| 1 · Deploy the shop | one Pod per component, tiers talk through Services |
| 2 · Switch off review | design for "not there" – degrade, do not crash |
| 3 · PostgreSQL as StatefulSet | stable identity, own PVC, headless Service |
| 4 · orders on PostgreSQL | init container instead of depends_on, Secret → env |
| 5 · Backup CronJob (3 TODOs) | CronJob → Job → Pod, run it now with `--from` |
| 6 · backup-viewer | ReadWriteMany: two Pods on one volume |

Sidecars are only in the slides and demo 07.

## Before the lab

- **Images:** `lab-02/shop/kustomization.yaml` points at `quay.io/tjungbau/shop-*:shop-test`.
  For the customer, change `newName`/`newTag` to the Nexus mirror **before** the students clone.
- **PostgreSQL / pg_dump image:** `registry.redhat.io/rhel9/postgresql-16:9.9-1793851884` – the
  cluster pull secret covers registry.redhat.io. **Viewer:** `registry.access.redhat.com/hi/python:3.12.16`.
- **RWX storage (task 5):** `backup/pvc.yaml` needs a StorageClass with ReadWriteMany (CephFS, NFS).
  If the default class is block storage, set `storageClassName` in `backup/pvc.yaml` for everyone.
- **NetworkPolicies from Lab 0** (default-deny, same-namespace, from-router to all Pods) do not block
  anything here – all traffic stays in the namespace or comes from the router.

## Run it (from `lab-02/`)

```bash
./trainer/lab-02-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-02-walkthrough.sh 5             # a single task
./trainer/lab-02-walkthrough.sh bonus
./trainer/lab-02-walkthrough.sh cleanup

./trainer/lab-02-solve.sh                     # all tasks + checks, no pauses
./trainer/lab-02-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-02-solve.sh -n user-01 check    # check a student's namespace
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | namespace (default: `lab`) |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

The scripts place test orders through the Route (one mug each, cookie `shop_session=lab02-<pid>`),
like the UI does.

### Checks

| Check | Meaning |
|---|---|
| Deployment web, catalog, cart, orders, review ready | task 1 |
| shop answers through the Route | task 1 |
| StatefulSet postgres ready, PVC data-postgres-0 bound | task 3 |
| orders has the init container wait-for-db, uses DATABASE_URL | task 4 |
| orders table in PostgreSQL has rows | task 4 – an order was placed after the switch |
| PVC backups bound, ReadWriteMany | task 5 |
| CronJob db-backup every 5 minutes | task 5 – the TODOs are filled in |
| backup-viewer lists a dump | task 6 – the Job ran and the second Pod sees the file |

### Files

| File | Purpose |
|------|---------|
| `shop/kustomization.yaml` | the shop base from `shop/deploy/base` + image names |
| `postgres/` | Secret, headless Service, StatefulSet – same as `shop/deploy/components/postgres` |
| `orders-postgres.yaml` | patch for orders: init container `wait-for-db` + `DATABASE_URL` |
| `backup/pvc.yaml`, `backup/cronjob.yaml` (3 TODOs), `backup/viewer.yaml` | task 5 and 6 |
| `reference/cronjob.yaml` | the finished CronJob |
| `trainer/lab-02-*.sh` | walkthrough, automatic solution, shared library |
