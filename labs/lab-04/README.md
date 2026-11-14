# Lab 4 – Overlays and a component (25 min)

Take the website from lab 3 – this time as plain YAML – and build a Kustomize layout around it:
a **base**, two **overlays** (dev and prod, running side by side in your namespace) and a
**component** that only prod uses. Then change the page and watch only dev roll out.

**You will learn**

- how a base and overlays fit together – and what an overlay may change without a patch
- why `namePrefix` needs care: the references Kustomize knows – and the one it does not
- why dev and prod in one namespace need different **selectors**
- how a `configMapGenerator` hash makes a configuration change roll out by itself
- that `oc apply -k` adds and changes – but never deletes

**How to work through this lab**

- Run every command from the folder `lab-04/`. You create `base/`, `overlays/` and `components/` in it.
- Every file is given as a `cat > … <<'EOF'` block: copy the whole block into the terminal, it
writes the file. Or open the file in your editor and paste the content between the `EOF` lines.
- After every task, **render** – `oc kustomize <folder>` prints exactly what would be applied.
- Stuck? `reference/` contains the finished files: `diff -r base reference/base`.

## Before you start

```bash
export NS=sbx-ws00           # your namespace – set it first
oc project $NS
oc version --client          # Kustomize is built into oc – this shows its version
```

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | The base | 5 min |
| 2 | Overlay dev – and a Route that points nowhere | 5 min |
| 3 | Overlay prod | 4 min |
| 4 | A component | 3 min |
| 5 | Preview and apply | 5 min |
| 6 | Change the page | 3 min |

---

### 1 · The base

**Goal:** everything every environment shares – Deployment, Service, Route and the web page.

```bash
mkdir -p base
cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: website
  labels:
    app.kubernetes.io/name: website
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: website
  template:
    metadata:
      labels:
        app.kubernetes.io/name: website
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
      - name: nginx
        image: quay.io/nginx/nginx-unprivileged:1.29.1
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          httpGet: { path: /, port: http }
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: [ALL] }
        volumeMounts:
        - name: page
          mountPath: /usr/share/nginx/html
      volumes:
      - name: page
        configMap:
          name: page            # generated – Kustomize adds the hash
EOF

cat > base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: website
  labels:
    app.kubernetes.io/name: website
spec:
  selector:
    app.kubernetes.io/name: website
  ports:
  - name: http
    port: 8080
    targetPort: http
EOF

cat > base/route.yaml <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: website
  labels:
    app.kubernetes.io/name: website
spec:
  to:
    kind: Service
    name: website
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

cat > base/index.html <<'EOF'
<html>
  <body>
    <h1>Hello from the base</h1>
  </body>
</html>
EOF

cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
- route.yaml
labels:
- pairs:
    app.kubernetes.io/part-of: website
  includeTemplates: true        # also on the Pods – the selectors stay untouched
configMapGenerator:
- name: page
  files:
  - index.html
EOF

oc kustomize base
```

**What happens**

- The three YAML files are plain Kubernetes objects – no templates, no placeholders. You could
apply them with `oc apply -f` as they are.
- `kustomization.yaml` makes the folder a Kustomize **base**:
- `oc kustomize base` renders the folder and prints the result. Nothing is sent to the cluster.

**Expected result:** four objects. The ConfigMap is called `page-<hash>` – and the Deployment's
volume refers to exactly that name, although `deployment.yaml` says `page`.

> **What to notice:** the base is complete and valid on its own. The generator adds a hash of
> the content to the ConfigMap name and rewrites every reference to it – that is what makes a
> page change roll out later (task 6).

**If it does not work**

- `accumulating resources from 'route.yaml' … no such file or directory` – a file name in
`resources` does not match the file: `ls base`.
- `MalformedYAMLError: yaml: line … did not find expected key` – an indentation problem in the
file named in the message.

---

### 2 · Overlay dev – and a Route that points nowhere

**Goal:** a dev variant with its own names, its own label and its own page – without copying the base.

```bash
mkdir -p overlays/dev
cat > overlays/dev/index.html <<'EOF'
<html>
  <body>
    <h1>Hello from DEV</h1>
  </body>
</html>
EOF

cat > overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namePrefix: dev-
labels:
- pairs:
    env: dev
  includeSelectors: true        # dev and prod run side by side: their selectors must differ
configMapGenerator:
- name: page
  behavior: replace             # the dev page instead of the base page
  files:
  - index.html
EOF

oc kustomize overlays/dev
```

**What happens**

| Field | Effect in dev |
|---|---|
| `resources: [../../base]` | starts with everything from the base |
| `namePrefix: dev-` | every object gets the prefix: `dev-website`, `dev-page-<hash>` |
| `labels` + `includeSelectors: true` | `env: dev` everywhere – **also** in the selectors of the Deployment and the Service |
| `configMapGenerator` + `behavior: replace` | the dev page replaces the base page |

Why the selectors? In task 5 dev and prod run in **one** namespace. Without `env` in the selector,
the Service `dev-website` would also send traffic to the prod Pods.

Now look closely at the Route:

```bash
oc kustomize overlays/dev | grep -A3 'to:'
```

**The Route still points to the Service** `website` – which does not exist: the Service is called
`dev-website`. Kustomize renames references it knows (Deployment → ConfigMap, Service → Pods),
but it does not know Routes. Teach it – in the base, so every overlay benefits:

```bash
cat > base/kustomizeconfig.yaml <<'EOF'
# Kustomize does not know that a Route refers to a Service – teach it,
# so namePrefix / nameSuffix also rename spec.to.name
nameReference:
- kind: Service
  fieldSpecs:
  - kind: Route
    path: spec/to/name
EOF

cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
- route.yaml
configurations:
- kustomizeconfig.yaml
labels:
- pairs:
    app.kubernetes.io/part-of: website
  includeTemplates: true        # also on the Pods – the selectors stay untouched
configMapGenerator:
- name: page
  files:
  - index.html
EOF

oc kustomize overlays/dev | grep -A3 'to:'
```

**Expected result:** now `name: dev-website`.

> **What to notice:** `namePrefix` renames objects – and only the references Kustomize knows.
> A Route's `spec.to.name`, a URL in an environment variable or a host in a config file stay
> as they are. `configurations` with a `nameReference` teaches Kustomize one more reference.

**If it does not work**

- `accumulating resources from '../base' … no such file or directory` – the path to the base
is wrong: the overlay must be in `overlays/dev/` and point to `../../base`.
- `… Name:"pages" … does not exist; cannot merge or replace` – the generator name in the overlay
must be `page`, the same as in the base.

---

### 3 · Overlay prod

**Goal:** a prod variant with two replicas and resource limits – a transformer and a patch.

```bash
mkdir -p overlays/prod
cat > overlays/prod/patch-resources.yaml <<'EOF'
# strategic merge: looks like the Deployment, the container is matched by name
apiVersion: apps/v1
kind: Deployment
metadata:
  name: website
spec:
  template:
    spec:
      containers:
      - name: nginx
        resources:
          requests: { cpu: 50m, memory: 64Mi }
          limits: { memory: 128Mi }
EOF

cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namePrefix: prod-
labels:
- pairs:
    env: prod
  includeSelectors: true
replicas:
- name: website
  count: 2
patches:
- path: patch-resources.yaml
EOF

oc kustomize overlays/prod
```

**What happens**

- `replicas` sets the replica count of the Deployment `website` – no patch needed.
- `patches` applies `patch-resources.yaml` as a **strategic merge** patch: it looks like a
Deployment, Kustomize finds the Deployment `website` and the container `nginx` by name and adds
the `resources` block.
- Patches and `replicas` use the names of the **base** (`website`) – the prefix is added afterwards.
- No `configMapGenerator`: prod serves the base page.

**Expected result:** `prod-website` with `replicas: 2`, the resources block, the base page in
`prod-page-<hash>`.

> **What to notice:** an overlay only contains the differences. Simple changes (replicas, images,
> labels) are fields of the kustomization; everything else is a patch.

---

### 4 · A component

**Goal:** a PodDisruptionBudget as an optional feature – written once, switched on by prod only.

```bash
mkdir -p components/pdb
cat > components/pdb/pdb.yaml <<'EOF'
# at least one Pod stays up during node maintenance (drain)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: website
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: website
EOF

cat > components/pdb/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
- pdb.yaml
EOF

cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namePrefix: prod-
labels:
- pairs:
    env: prod
  includeSelectors: true
replicas:
- name: website
  count: 2
patches:
- path: patch-resources.yaml
components:
- ../../components/pdb
EOF

oc kustomize overlays/prod | grep -B2 -A8 'kind: PodDisruptionBudget'
```

**What happens:** `kind: Component` (API `v1alpha1`) marks a reusable building block. The prod
overlay includes it with `components:` – and the overlay's prefix and labels apply to it as well.

**Expected result:** a PodDisruptionBudget `prod-website` whose selector contains
`env: prod` – it protects only the prod Pods.

> **What to notice:** overlays are environments, components are features. dev does not include
> the component – so dev has no PodDisruptionBudget.

---

### 5 · Preview and apply

**Goal:** see what would change, then deploy dev and prod side by side.

```bash
oc diff -k overlays/dev
oc apply -k overlays/dev
oc apply -k overlays/prod
oc get deployment,service,route,configmap,pdb -l 'env in (dev,prod)'
DEV_ROUTE=$(oc get route dev-website -o jsonpath='{.spec.host}')
PROD_ROUTE=$(oc get route prod-website -o jsonpath='{.spec.host}')
curl -k https://$DEV_ROUTE
curl -k https://$PROD_ROUTE
```

**What happens**

- `oc diff -k` renders the overlay and compares it with the live objects. The first time,
everything is new.
- `oc apply -k` renders and applies in one step.
- `-l 'env in (dev,prod)'` finds both variants by the label the overlays set.

**Expected result:** two Deployments (`dev-website` 1/1, `prod-website` 2/2), two Services, two
Routes, two ConfigMaps, one PodDisruptionBudget. `curl` shows `Hello from DEV` and
`Hello from the base`.

> **What to notice:** one base, two variants, one namespace – kept apart by the name prefix
> and the `env` selector.

**If it does not work**

- `oc diff` ends with exit code 1 – that is normal: it means "there are differences".
- A Route answers `503` – the Pods are not ready yet: `oc get pods -l env=dev`.

---

### 6 · Change the page

**Goal:** a configuration change that rolls out by itself – only where it changed.

```bash
cat > overlays/dev/index.html <<'EOF'
<html>
  <body>
    <h1>Hello from DEV – version 2</h1>
  </body>
</html>
EOF
oc diff -k overlays/dev
oc apply -k overlays/dev
oc rollout status deployment/dev-website
DEV_ROUTE=$(oc get route dev-website -o jsonpath='{.spec.host}')
curl -k https://$DEV_ROUTE
oc get pods -l 'env in (dev,prod)'
oc get configmap -l env=dev
```

**What happens:** the new page gives the ConfigMap a new hash – a **new** ConfigMap
`dev-page-<new hash>`. The Deployment refers to the new name, so its Pod template changes and
Kubernetes rolls out new Pods. prod uses another ConfigMap: nothing changes there.

**Expected result:** `oc diff` shows a new ConfigMap and the changed volume in the Deployment;
the dev Pod is new, the prod Pods keep their age; `curl` shows version 2. `oc get configmap`
lists **two** dev ConfigMaps – the old one is still there.

> **What to notice:** the hash turns "configuration changed" into "Pod template changed" – a
> rolling update without `oc rollout restart`. And `oc apply -k` never deletes: the old
> ConfigMap stays until you remove it (Argo CD can prune it – module 05).

---

## Cleanup

Lab 5 deploys the same website again – with Argo CD, from Git. Remove what `oc apply -k` created
here. Your files in `base/`, `overlays/` and `components/` stay: lab 5 pushes them to Git.

```bash
oc delete -k overlays/dev
oc delete -k overlays/prod
oc delete configmap -l app.kubernetes.io/part-of=website
oc get deployment,service,route,configmap,pdb -l app.kubernetes.io/part-of=website
```

**What happens**

- `oc delete -k` renders the overlay exactly like `oc apply -k` and deletes those objects:
Deployment, Service, Route, the **current** ConfigMap and – for prod – the PodDisruptionBudget.
- The old dev ConfigMap of task 6 is not in the rendered output any more (its hash changed), so
`oc delete -k` does not know it. The label `app.kubernetes.io/part-of: website` – set on every
object by the base – finds it.

**Expected result:** `No resources found` for the last command.

> **What to notice:** the same lesson as in task 6, from the other side: Kustomize only knows
> what it renders **now**. Objects that dropped out of the output need a label – or a tool that
> tracks them. That is what Argo CD's prune does in lab 5.
