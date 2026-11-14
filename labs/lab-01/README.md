# Lab 1 – Build and publish like a pro (30 min)

Build the catalogue API with a multi-stage Containerfile, tag it with version + git SHA, add
metadata, publish it, promote it by digest – and run exactly that image on OpenShift.

**You will learn**

- why a multi-stage build ships a smaller and safer image
- how to make an image traceable: a tag with version and commit, OCI labels, the digest
- how to promote an image from *dev* to *release* without rebuilding it
- how to run an image by digest – so that nobody can change what runs by re-pushing a tag

**How to work through this lab**

- Run every command from the folder `lab-01/` – it is inside the Git repository, which task 2
needs for the commit hash.
- You need `podman`, `skopeo`, `git` and `jq` on your machine, and `oc` logged in to the cluster.
- Each task has the commands to copy, an explanation of what they do, the result to expect,
a **What to notice** box and a list of the most common problems.

## Before you start

All students push into **one** repository on Nexus – your group name keeps the images apart.
Set everything first; all commands below use these variables:

```bash
export NS=sbx-ws00                               # your namespace
oc project $NS
export DEVREPO=$NS-dev                          # Repo for DEV Image
export RELEASEREPO=$NS-release                  # Repo for PROD Image
export REGISTRY=registry.acme.example            # the registry
export REGISTRYORG=workshop
export DEV=$REGISTRY/$REGISTRYORG/$DEVREPO           # your dev image – use YOUR group
export RELEASE=$REGISTRY/$REGISTRYORG/$RELEASEREPO   # your release image
podman login $REGISTRY                           # skopeo uses the same login
```

- `DEV` and `RELEASE` are image names without a tag – the tag is added in task 2.
- `podman login` stores the credentials in your auth file; `skopeo` reads the same file, so you
log in only once. Expected: `Login Succeeded!`
- The variables only live in this terminal: open a new terminal, set them again.

The app is in `shop-catalog/`: a small Python API (FastAPI) with `/items`, `/info` and `/health`.

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Read the Containerfile | 3 min |
| 2 | Build with version, revision and labels | 8 min |
| 3 | Compare build stage and final image | 4 min |
| 4 | Push and inspect | 5 min |
| 5 | Promote by digest | 4 min |
| 6 | Run it on OpenShift – by digest | 6 min |
| 7 | Clean up | 2 min |

---

### 1 · Read the Containerfile

**Goal:** understand what each stage of the build does before you run it.

```bash
cat shop-catalog/Containerfile shop-catalog/.containerignore
```

Read the Containerfile from top to bottom:

| Line(s) | What it does |
|---|---|
| `FROM …/python-312:9.6 AS build` | stage 1, named `build` – the full Python image with pip and compilers |
| `ARG PIP_INDEX_URL=…` | where pip downloads packages from – overridable for a Nexus mirror |
| `COPY --chown=1001:0 requirements.txt .` + `RUN pip install … --target /tmp/deps` | installs the pinned packages into a separate folder |
| `COPY --chown=1001:0 app ./app` | the source code – copied **after** the packages, owned by 1001 and group 0 |
| `RUN chmod -R g=u,o=rX …` | packages and code readable for **every** UID – see below |
| `FROM …/python-312-minimal:9.6` | stage 2 – a small runtime image without pip and compilers |
| `ARG VERSION … REVISION …` + `LABEL …` | build arguments that end up as OCI labels |
| `ENV … APP_VERSION=$VERSION APP_REVISION=$REVISION` | the same values as environment variables for the app (`/info`) |
| `COPY --from=build …` | takes only the packages and the code from stage 1 |
| `USER 1001`, `EXPOSE 8080`, `CMD …` | non-root user, port above 1024, start uvicorn |

`.containerignore` keeps `.git`, caches and local secrets (`.env`) out of the build context.

> **What to notice:** two `FROM` lines – stage 1 (`build`, `ubi9/python-312`) has pip and the
> build tools and installs the pinned packages into `/tmp/deps`; stage 2 (`python-312-minimal`)
> gets only those packages and the code. `requirements.txt` is copied before the code, so the
> dependency layer is cached. The base images are pinned to a version.
>
> `USER 1001` is the user the UBI Python images are built for. On OpenShift it does not matter
> which UID you write here – the `restricted-v2` SCC starts the container with a **random UID**
> from your project's range and **group 0**. What matters: a numeric, non-root `USER`, a port
> above 1024, and files that group 0 may read.
>
> That is why stage 1 uses `--chown=1001:0` and `chmod -R g=u,o=rX`: `COPY` keeps the file modes
> of your machine and makes `root` the owner – a file that is `-rw-------` on your laptop would be
> unreadable for the random UID, and the app crashes with `PermissionError`.

---

### 2 · Build with version, revision and labels

**Goal:** an image whose tag, labels and environment all say which version and which commit it is.

```bash
export VERSION=1.0.0
export SHA=$(git rev-parse --short --verify HEAD 2>/dev/null || echo nogit)
export TAG=$VERSION-$SHA
podman build --platform linux/amd64 -t $DEV:$TAG \
    --build-arg VERSION=$VERSION \
    --build-arg REVISION=$(git rev-parse HEAD) shop-catalog
podman inspect $DEV:$TAG --format '{{json .Labels}}' | jq 'with_entries(select(.key|startswith("org.opencontainers")))'
```

**What happens**

- `git rev-parse --short HEAD` prints the short hash of the current commit, e.g. `3f2a9c1`.
`TAG` becomes `1.0.0-3f2a9c1`.
- `podman build` builds both stages; `-t` names the result `$DEV:$TAG`. The two `--build-arg`
fill the `ARG`s of stage 2 – the full commit hash goes into `REVISION`.
- The last argument, `shop-catalog`, is the build context: the folder podman sends to the build.
- `podman inspect … | jq` prints only the labels that start with `org.opencontainers`.

**Expected result:** the build ends with the image ID; `podman inspect` shows

```json
{
  "org.opencontainers.image.revision": "<full commit hash>",
  "org.opencontainers.image.version": "1.0.0"
}
```

plus a few labels inherited from the Red Hat base image.

> Behind Nexus, pip needs the mirror: add `--build-arg PIP_INDEX_URL=https://<nexus>/repository/pypi/simple`.

**If it does not work**

- `fatal: not a git repository` – you are not inside the repository clone. Change into
`lab-01/` of your clone.
- `pip … Could not find a version` or a timeout in the `RUN pip install` step – the build cannot
reach pypi.org. Use the Nexus mirror with `--build-arg PIP_INDEX_URL=…` (see above).
- `Cannot connect to Podman` on macOS – start the machine: `podman machine start`.
- `jq: command not found` – leave out `| jq …` and read the full label list.

---

### 3 · Compare build stage and final image

**Goal:** see how much the second stage saves.

```bash
podman build --platform linux/amd64 --target build -t shop-catalog-build shop-catalog
podman images | grep -E "$DEV|shop"
```

**What happens:** `--target build` stops after stage 1 and tags that intermediate image as
`shop-catalog-build`. Most layers come from the cache of task 2, so this build is fast.
`podman images` lists both images with their sizes.

**Expected result:** two lines – `shop-catalog-build` and your `$DEV` image. Compare the
`SIZE` column.

> **What to notice:** the build stage is several hundred MB larger – the full Python image with
> pip, compilers and development headers. None of it is in the image you ship.

---

### 4 · Push and inspect

**Goal:** publish the image and read its digest from the registry.

```bash
podman push $DEV:$TAG
skopeo inspect docker://$DEV:$TAG | jq '{Digest, Labels}'
export DIGEST=$(skopeo inspect docker://$DEV:$TAG --format '{{.Digest}}')
echo $DIGEST
```

**What happens**

- `podman push` uploads the layers that the registry does not have yet, then the manifest.
- `skopeo inspect docker://…` asks the **registry** – not your local storage – for the image's
metadata. `jq '{Digest, Labels}'` keeps only those two fields.
- `--format '{{.Digest}}'` prints only the digest; `export DIGEST=…` keeps it for tasks 5 and 6.

**Expected result:** `echo $DIGEST` prints `sha256:` followed by 64 hex characters.

> **What to notice:** `skopeo inspect` reads labels and digest straight from the registry –
> no pull. The digest (`sha256:…`) is the image's content address: it can never point to
> anything else.

**If it does not work**

- `unauthorized` or `authentication required` – `podman login $REGISTRY` again; check that
`DEV` points to *your* group's repository.
- `DIGEST` is empty – `skopeo inspect` failed; run it without `--format` to see the error.

---

### 5 · Promote by digest

**Goal:** copy exactly the tested image from *dev* to *release* – without building it again.

```bash
skopeo copy docker://$DEV@$DIGEST docker://$RELEASE:$TAG
skopeo inspect docker://$RELEASE:$TAG --format '{{.Digest}}'
```

**What happens:** `skopeo copy` reads the image from the dev repository **by digest**
(`@sha256:…` – not by tag) and writes it into the release repository under the same tag. It
copies registry to registry; nothing is stored on your machine.

**Expected result:** the second command prints the **same** digest as `echo $DIGEST`.

> **What to notice:** registry to registry, no rebuild, no pull to your machine – and the digest
> in `release` is the same as in `dev`. You promote what you tested, bit for bit.

---

### 6 · Run it on OpenShift – by digest

**Goal:** deploy the release image by its digest and check that the running app reports the
version and commit you built.

```bash
oc create deployment shop-catalog --image=$RELEASE@$DIGEST --port=8080
oc rollout status deployment/shop-catalog
oc expose deployment shop-catalog --port=8080
oc create route edge shop-catalog --service=shop-catalog
ROUTE=$(oc get route shop-catalog -o jsonpath='{.spec.host}')
curl -sk https://$ROUTE/info
```

**What happens**

- `oc create deployment … --image=$RELEASE@$DIGEST` – the Deployment references the image by
digest. Look at it: `oc get deployment shop-catalog -o jsonpath='{.spec.template.spec.containers[0].image}'`.
- `oc rollout status` waits until the Pod is ready.
- `oc expose` and `oc create route edge` make it reachable, as in lab 0.
- `curl …/info` calls the endpoint that prints the app's version, revision and Pod name.

**Expected result:** JSON with `"version": "1.0.0"` and the full commit hash as revision.

`ImagePullBackOff`? The registry is private – give your namespace pull access
(robot account from the trainer):

```bash
oc create secret docker-registry acme-pull --docker-server=$REGISTRY \
    --docker-username="$ROBOT_USER" --docker-password="$ROBOT_TOKEN"
oc secrets link default acme-pull --for=pull
oc rollout restart deployment/shop-catalog
```

`oc secrets link default … --for=pull` adds the pull secret to the service account `default`,
which your Pods use – every new Pod in the namespace can pull from the registry. The rollout
restart creates a new Pod that uses it.

> **What to notice:** `/info` shows the same version and revision as the tag and the labels –
> the Containerfile copies the build args into `APP_VERSION` / `APP_REVISION`. The Deployment
> references the digest – a re-pushed tag cannot change what runs.
>
> Which UID does the Pod run with? `oc exec deploy/shop-catalog -- id` – not 1001, but the
> random UID OpenShift picked for your project, with group 0.

**If it does not work**

- `ImagePullBackOff` – see the pull secret above; `oc describe pod -l app=shop-catalog` shows the
exact error.
- `CrashLoopBackOff` with `exec format error` in `oc logs deploy/shop-catalog` – the image was
built for arm64. Build again with `--platform linux/amd64`, push, and use the new digest.
- `CrashLoopBackOff` with `PermissionError: [Errno 13] Permission denied: '/opt/app-root/src/app/…'`
– the random UID cannot read the code. Check the image as OpenShift runs it:
`podman run --rm --user 1000680000:0 $DEV:$TAG ls -la /opt/app-root/src/app` – the files must be
readable for others (`-rw-r--r--`). The Containerfile's `--chown=1001:0` and `chmod -R g=u,o=rX`
make sure of that; rebuild, push and use the new digest.
- `/info` answers `503` – the Pod is not ready yet: `oc get pods`.

---

### 7 · Clean up

**Goal:** remove what the lab created in your namespace and on your machine. The images in the
registry stay – they are the release you built and promoted.

In the cluster:

```bash
oc delete route/shop-catalog service/shop-catalog deployment/shop-catalog
```
