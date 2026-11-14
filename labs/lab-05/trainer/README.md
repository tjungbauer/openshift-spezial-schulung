# Lab 5 – Trainer: setup, walkthrough, solution and checks

The scripts live in `lab-05/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They run the commands of
the student README – Git repository, Applications, self heal, hook and wave, promotion by
digest, `git revert` – from `lab-05/`, with the same variables (`$NS`, `$REPO_URL`, `$WORK`).

## Before the training – one Argo CD per student

Students are not cluster admins, so the trainer creates an Argo CD instance in every student
namespace. Needs: cluster-admin, the **OpenShift GitOps operator** installed.

```bash
./trainer/lab-05-setup.sh user-01 user-02 user-03            # user name = namespace name
./trainer/lab-05-setup.sh user-01:alice user-02:bob          # NAMESPACE:USER if they differ
./trainer/lab-05-setup.sh --delete user-01 user-02           # remove the instances again
```

Per namespace: the `ArgoCD` CR `argocd` ([argocd.yaml](argocd.yaml)) – Route `argocd-server`,
admin password in the Secret `argocd-cluster` – and a Role/RoleBinding
([rbac.yaml](rbac.yaml)) that lets the user create Applications. A user-defined instance
manages only its own namespace. Each instance runs about five Pods (server, repo server,
application controller, Redis, …): check the **quota** of the student namespaces, and start
the setup well before module 05 – an instance needs 1–2 minutes.

**Git:** every student needs an **empty** repository on the ACME Git server and a token with
write access – the same token is used for `git push` and, read-only, by Argo CD. Hand out the
URL pattern (e.g. `https://git.acme.example/<user>/website-gitops.git`).

Test one namespace before the training:

```bash
GIT_REPO_URL=https://git.acme.example/trainer/website-gitops.git \
GIT_USERNAME=trainer ./trainer/lab-05-solve.sh -n user-01      # asks nothing – set GIT_TOKEN first
```

## Walkthrough, solution and checks

Both scripts use the shared demo library (`demos/lib`) and default to the namespace `lab`,
which they create (with its own Argo CD instance) and delete on cleanup. Other namespaces
(e.g. `user-01`) are only used, never deleted – cleanup removes the Applications, the dev and
prod objects and the repository Secret there; the Argo CD instance stays.

Needs: `oc` (logged in), `git`, `curl`, and a Git repository **the trainer owns** – the
scripts **force-push** to its branch `main`:

```bash
export GIT_REPO_URL=https://git.acme.example/trainer/website-gitops.git
export GIT_USERNAME=trainer
printf 'Git token: '; read -rs GIT_TOKEN; echo; export GIT_TOKEN
```

Run from `lab-05/`:

### Interactive walkthrough – present the lab live

```bash
./trainer/lab-05-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-05-walkthrough.sh 4             # a single task (earlier tasks are done quietly)
./trainer/lab-05-walkthrough.sh bonus         # prune
./trainer/lab-05-walkthrough.sh cleanup
./trainer/lab-05-walkthrough.sh -n user-01
```

Task 2 prints the Argo CD URL and the admin password – open the UI on the beamer before you
press ENTER for the Application. Task 1 pushes with `--force` (the trainer repository is
reused); students push to an empty repository without it.

### Automatic solution and checks

```bash
./trainer/lab-05-solve.sh                     # all tasks + checks
./trainer/lab-05-solve.sh 5                   # a single task
./trainer/lab-05-solve.sh bonus
./trainer/lab-05-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-05-solve.sh cleanup
LAB_NS=user-01 ./trainer/lab-05-solve.sh check   # check a student's namespace (no Git needed)
```

| Option / variable | Description |
|-------------------|-------------|
| `-n NAME`, `LAB_NS=NAME` | the namespace (default: `lab`) |
| `GIT_REPO_URL` | HTTPS URL of the trainer's repository – force-pushed |
| `GIT_USERNAME`, `GIT_TOKEN` | credentials for `git push` and the Argo CD repository Secret |
| `WORK_DIR=PATH` | where the repository is built (default `${TMPDIR:-/tmp}/lab-05-<namespace>`) |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

The token is never shown: the scripts push through a small `GIT_ASKPASS` helper in the work
folder, which cleanup deletes.

### Files

| File | Purpose |
|------|---------|
| `trainer/lab-05-setup.sh` | Argo CD instance + Application rights per student namespace |
| `trainer/argocd.yaml`, `trainer/rbac.yaml` | what the setup applies |
| `trainer/lab-05-walkthrough.sh` | interactive walkthrough |
| `trainer/lab-05-solve.sh` | automatic solution and checks |
| `trainer/lab-05-lib.sh` | tasks, checks and cleanup shared by both scripts |
| `application-dev.yaml`, `application-prod.yaml` | the Applications (`<NS>`, `<REPO_URL>` filled in with `sed`) |
| `files/` | hook, wave patch and the broken probe the students copy |
| `reference/` | the finished repository content (prod digest as a comment) |
