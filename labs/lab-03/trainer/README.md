# Lab 3 – Trainer: walkthrough, solution and checks

The scripts live in `lab-03/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They build the chart
`website` step by step in a work folder (default `${TMPDIR:-/tmp}/lab-03-<namespace>`)
from the files in `reference/` – exactly the files the students write in the README.
They can be started from any directory.

Both scripts use the shared demo library (`demos/lib`) and default to the namespace
`lab`, which they create and delete on cleanup. Other namespaces (e.g. `user-01`) are
only used, never deleted – cleanup only uninstalls the release `website` there.

Needs: `oc` (logged in), `helm` (3.x or 4.x) and `curl`.

Run from `lab-03/`:

### Interactive walkthrough – present the lab live

```bash
./trainer/lab-03-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-03-walkthrough.sh 3             # a single task (earlier tasks are filled in quietly)
./trainer/lab-03-walkthrough.sh bonus         # only the bonus task
./trainer/lab-03-walkthrough.sh cleanup
./trainer/lab-03-walkthrough.sh -n user-01
```

Every command is shown first and runs on ENTER (`q` quits). The commands show
`$REF` for `lab-03/reference/website` – the students write the same files with the
heredocs of the README. Each task ends with a discussion box. At the end the script
offers the bonus task, runs the checks and asks (in red) whether to delete the lab
resources.

### Automatic solution and checks

```bash
./trainer/lab-03-solve.sh                     # all tasks + checks
./trainer/lab-03-solve.sh 5                   # a single task
./trainer/lab-03-solve.sh bonus
./trainer/lab-03-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-03-solve.sh cleanup
LAB_NS=user-01 ./trainer/lab-03-solve.sh check   # check a student's namespace
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace (default: `lab`) |
| `WORK_DIR=PATH` | where the chart is built |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

The check `Upgrade and rollback done` needs at least three revisions (install,
upgrade, rollback). `Image from appVersion` fails if a student set `image.tag`.

### Files

| File | Purpose |
|------|---------|
| `trainer/lab-03-walkthrough.sh` | interactive walkthrough |
| `trainer/lab-03-solve.sh` | automatic solution and checks |
| `trainer/lab-03-lib.sh` | tasks, checks and cleanup shared by both scripts |
| `reference/website/` | the finished chart (students may use it) |
| `reference/bonus/` | ConfigMap and Deployment for the bonus task |
