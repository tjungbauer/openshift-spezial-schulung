# Lab 1 – Trainer: walkthrough, solution and checks

The scripts live in `lab-01/trainer/` so students do not find them right away
(the student instructions are in [../README.md](../README.md)). They work on the
lab files in `lab-01/` and can be started from any directory.

Both scripts use the shared demo library (`demos/lib`). Tasks 1–5 work on your
workstation and the registry; task 6 deploys into the namespace `lab` (created if
missing). Cleanup removes the lab objects and the local images, never the project
and never the pushed images.

Before you start:

```bash
# trainer – quay.io
export REGISTRY=quay.io/tjungbau        # -> quay.io/tjungbau/shop-catalog-dev and quay.io/tjungbau/shop-catalog
podman login quay.io                    # skopeo uses the same credentials

# or exactly like a student group on Nexus
export DEV=registry.acme.example/workshop/shop-group1-dev
export RELEASE=registry.acme.example/workshop/shop-group1-release
```

`DEV` and `RELEASE` win over `REGISTRY`.

Run from `lab-01/`:

### Interactive walkthrough – present the lab live

```bash
./trainer/lab-01-walkthrough.sh               # all tasks, ENTER runs each command
./trainer/lab-01-walkthrough.sh 4             # a single task
./trainer/lab-01-walkthrough.sh bonus         # build in the cluster
./trainer/lab-01-walkthrough.sh cleanup
./trainer/lab-01-walkthrough.sh -n user-01    # task 6 in another namespace
```

Same style as the demos: every command is shown first and runs on ENTER
(`q` quits). Each task ends with a discussion box. At the end the script offers
the bonus task, runs the checks and asks (in red) whether to clean up.

### Automatic solution and checks

```bash
./trainer/lab-01-solve.sh                     # all tasks + checks
./trainer/lab-01-solve.sh 5                   # a single task
./trainer/lab-01-solve.sh bonus
./trainer/lab-01-solve.sh check               # PASS / FAIL, exit code = number of failures
./trainer/lab-01-solve.sh cleanup
```

| Option / variable | Description |
|-------------------|-------------|
| `DEV=IMAGE`, `RELEASE=IMAGE` | full image names without tag – what the students set |
| `REGISTRY=HOST/ORG` | shortcut: `$REGISTRY/shop-catalog-dev` and `$REGISTRY/shop-catalog` |
| `PULL_USER`, `PULL_TOKEN` | task 6 creates a pull secret – needed when the release repository is private (quay.io creates new repositories as private) |
| `-n NAME`, `LAB_NS=NAME` | namespace for task 6 (default: `lab`) |
| `VERSION=X.Y.Z` | version (default: `1.0.0`) |
| `PLATFORM=OS/ARCH` | build platform (default: `linux/amd64`) |
| `PIP_INDEX_URL=URL` | PyPI mirror (Nexus) – passed to `podman build` as build arg |
| `DEMO_CLEANUP=y\|n` | answer the walkthrough's cleanup question in advance |
| `NO_COLOR=1` | no colours |

Outside a git checkout the revision is `0000000…` (the script warns). In the
students' clone of the lab repository it is the real commit.

Check a student group (their namespace and images):

```bash
DEV=registry.acme.example/workshop/shop-group1-dev \
RELEASE=registry.acme.example/workshop/shop-group1-release \
./trainer/lab-01-solve.sh -n user-01 check
```

### Checks

| Check | Meaning |
|---|---|
| dev image pushed | `$DEV:<tag>` exists in the registry |
| label version / revision | the OCI labels match `VERSION` and the git commit |
| release digest = dev digest | promoted by digest, not rebuilt |
| Deployment uses the release digest | `image: $RELEASE@sha256:…` |
| /info version / revision | the running app reports the same strings |
| Pod runs with group 0 | OpenShift's `restricted-v2` SCC: random UID, group 0 – not the `USER 1001` of the image |

### Files

| File | Purpose |
|------|---------|
| `trainer/lab-01-walkthrough.sh` | interactive walkthrough |
| `trainer/lab-01-solve.sh` | automatic solution and checks |
| `trainer/lab-01-lib.sh` | tasks, checks and cleanup shared by both scripts |
| `shop-catalog/` | the app: `Containerfile`, `.containerignore`, `requirements.txt`, `app/main.py` (FastAPI) |
