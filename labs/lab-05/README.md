# Lab 5 – Deploy the website with Argo CD (35 min)

The website of lab 4 goes into a Git repository – from now on Argo CD deploys it, not you. You
create an Application for dev, watch Argo CD repair a manual change, order the sync with a
hook and a wave, promote the exact image of dev to prod – and roll back a broken release with
`git revert`.

**You will learn**

- how an Argo CD Application connects a Git folder with a namespace
- what **self heal** does with manual changes – and why `oc scale` no longer "works"
- how a **PreSync hook** and a **sync wave** put a sync in order
- how to promote **by digest**: prod gets exactly the image that runs in dev
- why the roll back is a `git revert` – and not `oc rollout undo`

**How to work through this lab**

- Run every command from the folder `lab-05/`. Your Git repository is a separate folder,
  `$WORK` (default `~/website-gitops`); the commands write into it with `"$WORK/…"` and
  `git -C "$WORK"` – you never have to change directories.
- Every task ends with a **commit and push**. Argo CD only sees what is in Git.
- Argo CD checks Git every three minutes. Do not wait – the `oc annotate … refresh` command in
  the tasks (or **REFRESH** in the UI) makes it look now.
- Stuck? `reference/` contains the finished repository content.

## Before you start

You need from the trainer: your **namespace**, the **URL of your Git repository** on the ACME
Git server and your **Git user and token**. Your namespace already contains your own Argo CD
instance (`argocd`).

Create an **empty** repository `website-gitops` in the web UI of the Git server – no README, no
licence file – and copy its HTTPS URL. Then:

```bash
export NS=user-01                                                 # your namespace
export REPO_URL=https://git.acme.example/user-01/website-gitops.git   # your repository
export GIT_USER=user-01                                           # your Git user
export WORK=~/website-gitops                                      # your local copy
oc project $NS
git --version                                                     # 2.28 or newer
```

Your token – typed, not shown, not in the shell history:

```bash
printf 'Git token: '; read -rs GIT_TOKEN; echo
```

From now on Argo CD creates `dev-website` and `prod-website`. If they are still in your namespace
(the cleanup of lab 4 was skipped), delete them first:

```bash
oc delete deployment,service,route,configmap,pdb -l app.kubernetes.io/part-of=website
```

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Push the website to Git | 5 min |
| 2 | Your Argo CD – and an Application for dev | 7 min |
| 3 | Fight Argo CD – self heal | 3 min |
| 4 | Order the sync – a hook and a wave | 7 min |
| 5 | Promote to prod – by digest | 7 min |
| 6 | Break it – roll back with `git revert` | 6 min |

---

### 1 · Push the website to Git

**Goal:** the base, the overlays and the component of lab 4 in your Git repository.

```bash
mkdir -p "$WORK"
cp -r ../lab-04/base ../lab-04/overlays ../lab-04/components "$WORK"/
```

Lab 4 not finished? Take the reference instead – **without** the files of this lab, so you can
add them yourself in task 4:

```bash
cp -r ../lab-04/reference/base ../lab-04/reference/overlays ../lab-04/reference/components "$WORK"/
```

Check that it renders, then commit and push:

```bash
oc kustomize "$WORK/overlays/dev" | grep -E '^kind|^  name'
git -C "$WORK" init -b main
git -C "$WORK" config user.name "$NS"
git -C "$WORK" config user.email "$NS@training.example"
git -C "$WORK" add .
git -C "$WORK" commit -m "website: base, dev and prod overlays"
git -C "$WORK" remote add origin "$REPO_URL"
git -C "$WORK" push -u origin main            # user: $GIT_USER, password: your token
```

**What happens:** `git init -b main` creates the repository with the branch `main` – the
Application uses that branch. `git config` without `--global` sets your name only for this
repository. The first push sends everything to the Git server.

**Expected result:** the push ends with `main -> main`; the web UI of the Git server shows
`base/`, `overlays/` and `components/`.

> **What to notice:** the repository holds no `oc` commands and no namespace – only the
> desired state. Who applies it, and where, is decided by the Application.

**If it does not work**

- `error: unknown switch 'b'` – your Git is older than 2.28: `git -C "$WORK" init` and then
  `git -C "$WORK" checkout -b main`.
- `remote origin already exists` – you ran the command twice; ignore it.
- `rejected … fetch first` – the repository was not empty (README?). Delete and create it
  again empty, or ask the trainer.
- `Authentication failed` – user and token, not your password. The token needs write access.

---

### 2 · Your Argo CD – and an Application for dev

**Goal:** log in to your Argo CD and let it deploy `overlays/dev`.

Your Argo CD runs in your namespace. Its URL and the password of the user `admin`:

```bash
ARGOCD=$(oc get route argocd-server -o jsonpath='{.spec.host}')
echo https://$ARGOCD
oc extract secret/argocd-cluster --keys=admin.password --to=-
```

Open the URL, log in as `admin` with that password.

Your repository is private – Argo CD needs read access. A Secret with the label
`argocd.argoproj.io/secret-type=repository` tells it the credentials for this URL:

```bash
oc create secret generic website-gitops-repo \
  --from-literal=type=git --from-literal=url="$REPO_URL" \
  --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN"
oc label secret website-gitops-repo argocd.argoproj.io/secret-type=repository
```

Now the Application – read it first, then fill in your namespace and URL and apply it:

```bash
cat application-dev.yaml
sed -e "s|<NS>|$NS|g" -e "s|<REPO_URL>|$REPO_URL|" application-dev.yaml | oc apply -f -
oc get applications.argoproj.io
oc get deployment,service,route
```

**What happens:** the Application lives in your namespace, next to your Argo CD – only this
instance sees it. Argo CD renders `overlays/dev` from the branch `main` (Kustomize, detected
by the `kustomization.yaml`) and applies the result to your namespace. `automated` syncs every
change in Git, `prune` deletes what disappears from Git, `selfHeal` repairs manual changes.

**Expected result:** after a few seconds `website-dev` shows `Synced` and `Healthy`;
`dev-website` runs. In the UI: the Application tile, click it – the resource tree. Open the
website:

```bash
ROUTE=$(oc get route dev-website -o jsonpath='{.spec.host}')
curl -k https://$ROUTE
```

> **What to notice:** you did not run `oc apply -k` – Argo CD did. The Application is the
> only object you created by hand; everything else comes from Git.

**If it does not work**

- The login page does not accept the password – copy it again without the line `# admin.password`.
- `Unknown` / `ComparisonError … authentication required` – the repository Secret is missing
  or the token is wrong: `oc get secret website-gitops-repo --show-labels`.
- `… app path does not exist` – the push of task 1 did not arrive, or the branch is not `main`.
- `forbidden` when you apply the Application – ask the trainer (setup of your namespace).

---

### 3 · Fight Argo CD – self heal

**Goal:** see what happens to a manual change of an object Argo CD manages.

```bash
oc scale deployment/dev-website --replicas=5
oc get deployment dev-website -w             # watch READY – Ctrl-C after a few seconds
```

**What happens:** `oc scale` changes `spec.replicas` in the cluster. Argo CD sees the
difference to Git (`replicas: 1` from the base), the Application is `OutOfSync` for a moment –
self heal syncs it back.

**Expected result:** the Deployment goes to 5 – and a few seconds later back to 1. In the UI
the **LAST SYNC** of `website-dev` is a few seconds old – the automatic repair.

> **What to notice:** with GitOps, `oc scale`, `oc edit` and `oc set image` no longer change
> anything for long. The change belongs in Git – a commit, reviewed, with history.

---

### 4 · Order the sync – a hook and a wave

**Goal:** a Job that runs **before** every sync (PreSync hook), and a Route that is created
**last** (sync wave 1).

```bash
cat files/presync-job.yaml files/patch-route-wave.yaml
cp files/presync-job.yaml files/patch-route-wave.yaml "$WORK/overlays/dev/"
```

The dev kustomization gets both files – the complete file:

```bash
cat > "$WORK/overlays/dev/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
- presync-job.yaml              # PreSync hook
namePrefix: dev-
labels:
- pairs:
    env: dev
  includeSelectors: true
configMapGenerator:
- name: page
  behavior: replace
  files:
  - index.html
patches:
- path: patch-route-wave.yaml   # sync wave 1 for the Route
EOF
```

Render, commit, push – and tell Argo CD to look now:

```bash
oc kustomize "$WORK/overlays/dev" | grep -E 'argocd.argoproj.io|^kind'
git -C "$WORK" add .
git -C "$WORK" commit -m "dev: PreSync hook and sync wave for the Route"
git -C "$WORK" push
oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite
```

Watch the sync in the UI (click **SYNC STATUS** / the last sync), then:

```bash
oc get job dev-prepare
oc logs job/dev-prepare
```

**What happens:** objects with the annotation `argocd.argoproj.io/hook: PreSync` are not part
of the normal sync – Argo CD runs them first and waits until the Job has finished.
`BeforeHookCreation` deletes the Job of the previous sync before the next one. Then the waves:
everything without an annotation is wave 0; wave 1 (the Route) starts when wave 0 is healthy.

**Expected result:** `dev-prepare` with `1/1` completions; the log shows
`PreSync: preparing the release …`. The UI shows the Job as a hook in the resource tree.

> **What to notice:** waves and hooks are annotations in Git – no script decides the order.
> Real projects put database migrations into the PreSync hook: if it fails, the new version
> is not rolled out.

**If it does not work**

- Nothing happens – the refresh annotation was set before the push arrived; run the
  `oc annotate` command again, or press **REFRESH** in the UI.
- The sync hangs at the hook – `oc get pods -l job-name=dev-prepare`, `oc logs job/dev-prepare`.

---

### 5 · Promote to prod – by digest

**Goal:** prod runs exactly the image that was tested in dev – pinned by its digest, not by a
tag that could be pushed again.

The digest of the image the dev Pod really runs:

```bash
DIGEST=$(oc get pod -l app.kubernetes.io/name=website,env=dev \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | cut -d@ -f2)
echo "$DIGEST"                               # sha256:…
```

Pin it in the prod overlay (no quotes around `EOF` – `$DIGEST` is filled in):

```bash
cat >> "$WORK/overlays/prod/kustomization.yaml" <<EOF
images:
- name: quay.io/nginx/nginx-unprivileged
  digest: ${DIGEST}
EOF
oc kustomize "$WORK/overlays/prod" | grep 'image:'
git -C "$WORK" add .
git -C "$WORK" commit -m "prod: promote the dev image by digest"
git -C "$WORK" push
```

And the Application for prod:

```bash
sed -e "s|<NS>|$NS|g" -e "s|<REPO_URL>|$REPO_URL|" application-prod.yaml | oc apply -f -
oc get applications.argoproj.io
oc get deployment prod-website -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**What happens:** `imageID` in the Pod status is the image the node pulled – with its digest.
The `images:` entry with `digest` makes Kustomize write `image@sha256:…` instead of
`image:1.29.1`. The second Application deploys `overlays/prod`: two replicas, resources, the
PodDisruptionBudget.

**Expected result:** `website-prod` `Synced` / `Healthy`; the image of `prod-website` ends with
`@sha256:…` – the same digest as `$DIGEST`.

> **What to notice:** promotion is a commit that changes one line in the prod overlay – it can
> be reviewed and reverted. Nothing is rebuilt for prod.

**If it does not work**

- `DIGEST` is empty – no dev Pod is running: `oc get pods -l env=dev`.
- `images` appears twice in the kustomization – you ran the `cat >>` twice; open
  `"$WORK/overlays/prod/kustomization.yaml"` and delete one block.

---

### 6 · Break it – roll back with `git revert`

**Goal:** a broken release in dev – and the roll back the GitOps way.

The bad commit: a typo in the readiness probe.

```bash
cat files/patch-broken-probe.yaml
cp files/patch-broken-probe.yaml "$WORK/overlays/dev/"
printf -- '- path: patch-broken-probe.yaml\n' >> "$WORK/overlays/dev/kustomization.yaml"
git -C "$WORK" add .
git -C "$WORK" commit -m "dev: new readiness probe"
git -C "$WORK" push
oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite
oc get pods -l app.kubernetes.io/name=website,env=dev -w     # Ctrl-C when the new Pod stays 0/1
```

The `printf` appends one line to the list `patches:` – the last entry of the file.

**Expected result:** a new Pod that stays `0/1` – the probe asks for `/healthz-typo`, nginx
answers 404. The old Pod keeps running, the website still answers. The Application is
`Synced`, but `Progressing` (after 10 minutes – `progressDeadlineSeconds` – it would turn
`Degraded`).

The roll back – a new commit that undoes the bad one:

```bash
git -C "$WORK" revert --no-edit HEAD
git -C "$WORK" push
oc annotate applications.argoproj.io website-dev argocd.argoproj.io/refresh=normal --overwrite
oc get pods -l app.kubernetes.io/name=website,env=dev -w     # the broken Pod disappears
git -C "$WORK" log --oneline
```

**What happens:** `git revert` creates a new commit with the opposite change – the history
keeps both. Argo CD syncs it like any other commit; the broken ReplicaSet is scaled down.

**Expected result:** one Pod `1/1`; the Application `Synced` / `Healthy`; `git log` shows the
bad commit and its revert.

> **What to notice:** the rolling update protected you – the old Pod kept serving. The roll
> back is a reviewed commit, and auto-sync stays on. `oc rollout undo` would be overwritten by
> self heal within seconds – try it if you do not believe it.

---

## Done early? Bonus

- **Prune:** remove the component from prod – delete the two lines `components:` and
  `- ../../components/pdb` in `"$WORK/overlays/prod/kustomization.yaml"`, commit, push,
  refresh `website-prod`. Is the PodDisruptionBudget gone? Compare with the bonus of lab 4,
  where `oc apply -k` kept it.
- **Undo by hand:** `oc rollout undo deployment/dev-website` – what does self heal do?
- **Diff:** change the dev page in Git **without** pushing – what does the UI show? And after
  the push, before the refresh? (**APP DIFF**)

## Cleanup

The Applications have no deletion finalizer – deleting them leaves the objects. Delete both:

```bash
oc delete applications.argoproj.io website-dev website-prod
oc delete deployment,service,route,configmap,pdb,job -l 'env in (dev,prod)'
oc delete secret website-gitops-repo
```
