# Lab 4 – Trainer: walkthrough, solution and checks

The scripts live in `lab-04/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They build the
Kustomize layout step by step in a work folder (default `${TMPDIR:-/tmp}/lab-04-<namespace>`)
from the files in `reference/` – exactly the files the students write in the README.
They can be started from any directory.

Both scripts use the shared demo library (`demos/lib`) and default to the namespace
`lab`, which they create and delete on cleanup. Other namespaces (e.g. `user-01`) are
only used, never deleted – cleanup removes the dev and prod objects of the lab there.

Needs: `oc` (logged in) and `curl`. No standalone `kustomize` – everything runs through
`oc kustomize`, `oc diff -k` and `oc apply -k`.

Run from `lab-04/`:

### Interactive walkthrough – present the lab live

```bash
./trainer/lab-04-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-04-walkthrough.sh 2             # a single task (earlier tasks are filled in quietly)
./trainer/lab-04-walkthrough.sh bonus         # only the bonus tasks
./trainer/lab-04-walkthrough.sh cleanup
./trainer/lab-04-walkthrough.sh -n user-01
```

The commands show `$REF` for `lab-04/reference`. Task 2 first renders the dev overlay
**without** the `configurations` of the base – the Route points to `website` – then adds them.
Tasks 1 and 3 write the kustomization of that step with `grep -v` from the reference file
(without the lines a later task adds).

### Automatic solution and checks

```bash
./trainer/lab-04-solve.sh                     # all tasks + checks
./trainer/lab-04-solve.sh 5                   # a single task
./trainer/lab-04-solve.sh bonus
./trainer/lab-04-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-04-solve.sh cleanup
LAB_NS=user-01 ./trainer/lab-04-solve.sh check   # check a student's namespace
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace (default: `lab`) |
| `WORK_DIR=PATH` | where the files are built |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

### Files

| File | Purpose |
|------|---------|
| `trainer/lab-04-walkthrough.sh` | interactive walkthrough |
| `trainer/lab-04-solve.sh` | automatic solution and checks |
| `trainer/lab-04-lib.sh` | tasks, checks and cleanup shared by both scripts |
| `reference/` | the finished base, overlays and component (students may use them) |
