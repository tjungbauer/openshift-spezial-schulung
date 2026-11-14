# Lab 0 – Trainer: walkthrough, solution and checks

The scripts live in `lab-00/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They work on the
lab files in `lab-00/` and can be started from any directory.

Every student has two namespaces, e.g. `sbx-ws01` (the app) and
`sbx-ws01-neighbour` (plays "another team" – only a toolbox runs there, from
task 5 on). The scripts do the same: the namespace given with `-n` gets the
app, `NEIGHBOUR_NS` (default: `<namespace>-neighbour`) gets the toolbox.

Both scripts use the shared demo library (`demos/lib`) and default to the
namespaces `lab` and `lab-neighbour`. They create these two and delete them on
cleanup. Other namespaces (e.g. `sbx-ws01` / `sbx-ws01-neighbour`) are only
used, never deleted – cleanup only removes the lab objects in them.

Run from `lab-00/`:

### Interactive walkthrough – present the lab live

```bash
./trainer/lab-00-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-00-walkthrough.sh 4             # a single task
./trainer/lab-00-walkthrough.sh bonus         # only the bonus tasks
./trainer/lab-00-walkthrough.sh cleanup
./trainer/lab-00-walkthrough.sh -n sbx-ws01      # uses sbx-ws01-neighbour as second namespace
```

Same style as the demos: every command is shown first and runs on ENTER
(`q` quits). Each task ends with a discussion box. Every reachability test is
compared with the expected result (`✔ as expected` / `✘ expected …`). At the
end the script offers the bonus tasks, runs the checks and asks (in red)
whether to delete the lab resources.

### Automatic solution and checks

```bash
./trainer/lab-00-solve.sh                     # setup + all tasks + checks
./trainer/lab-00-solve.sh setup               # make sure both namespaces exist
./trainer/lab-00-solve.sh 4                   # a single task
./trainer/lab-00-solve.sh bonus
./trainer/lab-00-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-00-solve.sh cleanup
LAB_NS=sbx-ws01 ./trainer/lab-00-solve.sh check   # check a student (sbx-ws01 + sbx-ws01-neighbour)
```

The same tasks as the walkthrough, without pauses, file listings or discussions.

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace with the app (default: `lab`) |
| `NEIGHBOUR_NS=NAME` | the second namespace (default: `<LAB_NS>-neighbour`) |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

The check `ConfigMap hello-page has index.html` accepts the page under `data`
**or** `binaryData` (see the note in task 4 of the student README).

### Files

| File | Purpose |
|------|---------|
| `trainer/lab-00-walkthrough.sh` | interactive walkthrough |
| `trainer/lab-00-solve.sh` | automatic solution and checks |
| `trainer/lab-00-lib.sh` | tasks, probes, checks and cleanup shared by both scripts |
| `reference/deployment.yaml` | the finished Deployment of task 3 (students may use it) |
