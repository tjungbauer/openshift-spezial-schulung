# Lab 3 – Your own Helm chart (30 min)

Build a chart from scratch for a simple website: a **Deployment**, a **Service** and a
**Route**, with a few values. Then install it, upgrade it and roll it back.

**You will learn**

- what `helm create` generates – and what you really need of it
- the roles of `Chart.yaml`, `values.yaml`, the templates and `_helpers.tpl`
- how values, `.Chart` and `.Release` get into the rendered YAML
- how to check a chart before it reaches the cluster: `helm lint`, `helm template`
- what a release and a revision are – install, upgrade, rollback

**How to work through this lab**

- Run every command from the folder `lab-03/`. Your chart is created in `lab-03/website/`.
- Every file is given as a `cat > … <<'EOF'` block: copy the whole block into the terminal, it
  writes the file. Or open the file in your editor and paste the content between the `EOF` lines.
- After writing a template, **render it** – that is how you find mistakes early.
- Stuck? `reference/website/` is the finished chart; compare your files with it
  (`diff -r website reference/website`).

## Before you start

```bash
export NS=user-01            # your namespace – set it first
oc project $NS
helm version                 # Helm 3.x or 4.x
```

All commands are run from `lab-03/`. The website is the nginx image you know from lab 0
(`quay.io/nginx/nginx-unprivileged`, port 8080) – it shows the nginx welcome page.

`helm version` should print a version – the chart works with Helm 3 and Helm 4. `helm` uses the
same login and the same current project as `oc`: what `oc project` shows is where Helm installs.

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Scaffold a chart | 4 min |
| 2 | Chart.yaml and values.yaml | 5 min |
| 3 | The Deployment template | 7 min |
| 4 | Service, Route and NOTES | 5 min |
| 5 | Render, lint, install | 5 min |
| 6 | Upgrade and roll back | 4 min |

### 1 · Scaffold a chart

**Goal:** a chart skeleton – and an idea of what a chart consists of.

```bash
helm create website
find website -type f | sort
```

**What happens:** `helm create website` creates the folder `website/` with a complete example
chart that would deploy nginx. `find` lists its files:

| File | Purpose |
|---|---|
| `Chart.yaml` | name, chart version, application version |
| `values.yaml` | the defaults for every value the templates use |
| `.helmignore` | files left out when the chart is packaged |
| `templates/*.yaml` | Deployment, Service, Ingress, HPA, ServiceAccount … – rendered into Kubernetes objects |
| `templates/_helpers.tpl` | named templates (helpers) – never an object itself |
| `templates/NOTES.txt` | text shown after install and upgrade |
| `templates/tests/` | a `helm test` Pod |

The exact list depends on your Helm version.

`helm create` gives you a complete example chart. We keep only the helpers and write
the rest ourselves:

```bash
find website/templates -mindepth 1 ! -name _helpers.tpl -delete
cat website/templates/_helpers.tpl
```

`find … -mindepth 1 ! -name _helpers.tpl -delete` deletes everything below `templates/` except
`_helpers.tpl` – including the `tests/` folder. Read the helpers you keep:

| Helper | Returns | Example for release `website` |
|---|---|---|
| `website.name` | the chart name (or `nameOverride`) | `website` |
| `website.fullname` | the name for every object: release name + chart name, but only once if one contains the other | `website` |
| `website.chart` | chart name and version for a label | `website-0.1.0` |
| `website.labels` | all standard labels: chart, name, instance, version, managed-by | five lines |
| `website.selectorLabels` | only the two labels that never change: name and instance | two lines |

> **What to notice:** `_helpers.tpl` defines named templates – `website.fullname`,
> `website.labels`, `website.selectorLabels`. Files starting with `_` are never rendered
> as Kubernetes objects. We call these helpers with `include "website.labels" .`

**If it does not work**

- `Error: … already exists` – `website/` is left from an earlier try. `rm -rf website`, start again.
- `helm: command not found` – install Helm or ask the trainer.

### 2 · Chart.yaml and values.yaml

**Goal:** describe the chart and decide which settings a user of the chart may change.

```bash
cat > website/Chart.yaml <<'EOF'
apiVersion: v2
name: website
description: A simple website – Deployment, Service and Route
type: application
version: 0.1.0          # the chart – raise it when you change the chart
appVersion: "1.29.1"    # the nginx version – default image tag
EOF

cat > website/values.yaml <<'EOF'
# Values of the website chart – only what we really want to change.

replicaCount: 1

image:
  repository: quay.io/nginx/nginx-unprivileged
  tag: ""               # empty: use appVersion from Chart.yaml

route:
  enabled: true
  host: ""              # empty: OpenShift generates the host name
EOF
```

**What happens:** both commands overwrite the generated files.

- `Chart.yaml`: `apiVersion: v2` is the chart format of Helm 3 and 4. `version` is the version of
  the **chart** – raise it whenever you change a template. `appVersion` is the version of the
  **application** – here the nginx version; the Deployment uses it as the default image tag.
- `values.yaml`: five values in three groups – the number of Pods, the image, the Route. An empty
  string means "not set": the templates then use a default.

**Expected result:** `cat website/Chart.yaml website/values.yaml` shows exactly the two files.

> **What to notice:** `version` is the chart, `appVersion` the application inside.
> `values.yaml` holds the defaults – and only the knobs you want to offer. Everything
> else stays fixed in the templates.

### 3 · The Deployment template

**Goal:** a Deployment whose name, labels, replicas and image come from the chart and the values.

```bash
cat > website/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "website.fullname" . }}
  labels:
    {{- include "website.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "website.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "website.labels" . | nindent 8 }}
    spec:
      securityContext:              # PodSecurity "restricted"
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
EOF
helm template website ./website --show-only templates/deployment.yaml
```

**What happens:** the heredoc writes the template, `helm template … --show-only` renders only
this one file locally – nothing is sent to the cluster. Go through the template line by line:

| Template | Rendered as | Comes from |
|---|---|---|
| `{{ include "website.fullname" . }}` | `website` | helper, release name + chart name |
| `{{- include "website.labels" . \| nindent 4 }}` | five label lines, indented by 4 | helper |
| `{{ .Values.replicaCount }}` | `1` | `values.yaml` |
| `{{- include "website.selectorLabels" . \| nindent 6 }}` | `name` and `instance` | helper |
| `{{ .Chart.Name }}` | `website` | `Chart.yaml` |
| `{{ .Values.image.tag \| default .Chart.AppVersion }}` | `1.29.1` | `image.tag` is empty – so `appVersion` |

The `.` you pass to `include` is everything Helm knows – the helpers need it to read
`.Release.Name` and `.Chart.Name`.

**Expected result:** a complete Deployment named `website` with the image
`quay.io/nginx/nginx-unprivileged:1.29.1`. Try a value: add `--set replicaCount=2` or
`--set image.tag=1.29.0` to the `helm template` command and watch the output change.

> **What to notice:** `{{ .Values.replicaCount }}` comes from `values.yaml`,
> `{{ .Chart.AppVersion }}` from `Chart.yaml`, the name and labels from the helpers.
> `{{-` removes the whitespace before it, `nindent 4` adds a newline and indents by 4.
> The selector uses only the **selector labels** – the version label may change, the
> selector may not.

**If it does not work**

- `Error: YAML parse error … did not find expected key` – an indentation problem in the
  template, often a missing `-` in `{{-` or a wrong `nindent` number. Compare with
  `reference/website/templates/deployment.yaml`.
- `Error: could not find template templates/deployment.yaml` – the file name or folder is wrong:
  `ls website/templates`.
- `nil pointer evaluating interface {}.repository` – `values.yaml` has no `image:` block; redo task 2.

### 4 · Service, Route and NOTES

**Goal:** make the website reachable – and switchable: the Route only when it is wanted.

```bash
cat > website/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ include "website.fullname" . }}
  labels:
    {{- include "website.labels" . | nindent 4 }}
spec:
  selector:
    {{- include "website.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: 8080
      targetPort: http
EOF

cat > website/templates/route.yaml <<'EOF'
{{- if .Values.route.enabled }}
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ include "website.fullname" . }}
  labels:
    {{- include "website.labels" . | nindent 4 }}
spec:
  {{- with .Values.route.host }}
  host: {{ . }}
  {{- end }}
  to:
    kind: Service
    name: {{ include "website.fullname" . }}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
{{- end }}
EOF

cat > website/templates/NOTES.txt <<'EOF'
Release {{ .Release.Name }} (revision {{ .Release.Revision }}) in namespace {{ .Release.Namespace }}.
{{- if .Values.route.enabled }}

Open the website:
  ROUTE=$(oc get route {{ include "website.fullname" . }} -n {{ .Release.Namespace }} -o jsonpath='{.spec.host}')
  curl -k https://$ROUTE
{{- end }}
EOF
```

**What happens:** three more files.

- `service.yaml` – selects the Pods with the **selector labels** (the same two as the Deployment's
  selector) and forwards port 8080 to the container port named `http`.
- `route.yaml` – the whole file sits inside `{{- if .Values.route.enabled }} … {{- end }}`: with
  `route.enabled=false` Helm renders nothing for it. `{{- with .Values.route.host }}` adds the
  `host:` line only when a host is given – an empty string counts as "not set", and OpenShift
  generates a host name.
- `NOTES.txt` – plain text with template expressions; Helm prints it after install and upgrade.
  `.Release.Name`, `.Release.Revision` and `.Release.Namespace` are filled in by Helm.

Check the result: `helm template website ./website` now prints three objects, the last command
of the block prints only `kind: Service` and `kind: Deployment` – the Route is gone.

> **What to notice:** `if` switches the whole Route on or off. `with` sets `host` only
> when a value is given – inside `with`, the dot **is** the host. `NOTES.txt` is printed
> after every install and upgrade.

**If it does not work**

- `nil pointer evaluating interface {}.enabled` – `values.yaml` has no `route:` block; redo task 2.
- The Route is always missing – check `{{- if .Values.route.enabled }}` (capital `V` in `Values`).

### 5 · Render, lint, install

**Goal:** check the chart, then install it as a release and open the website.

```bash
helm lint website
helm template website ./website
helm template website ./website --set route.enabled=false | grep kind:
helm install website ./website
helm list
oc get deployment,service,route -l app.kubernetes.io/instance=website
ROUTE=$(oc get route website -o jsonpath='{.spec.host}')
curl -k https://$ROUTE
```

**What happens**

- `helm lint website` checks the chart for errors and common problems (it renders the templates
  and checks `Chart.yaml`).
- `helm template website ./website` renders everything locally – the first argument is the
  release name, the second the chart folder.
- `helm install website ./website` renders the chart again and creates the objects in your
  current project as the release `website`. Then it prints the release status and your `NOTES.txt`.
- `helm list` shows the releases of the project.
- `oc get … -l app.kubernetes.io/instance=website` finds every object of the release by the
  label the helpers set.
- `curl` calls the Route, as in lab 0.

**Expected result**

- `helm lint`: `1 chart(s) linted, 0 chart(s) failed` – an `[INFO] Chart.yaml: icon is recommended`
  line is fine.
- `helm install`: `STATUS: deployed`, `REVISION: 1`, then your NOTES.
- `helm list`: one line, `website`, revision 1, status `deployed`, chart `website-0.1.0`,
  app version `1.29.1`.
- `curl`: the HTML of the nginx welcome page (`<title>Welcome to nginx!</title>`).

> **What to notice:** `helm template` renders locally – nothing reaches the cluster.
> `helm install` creates the release **website**, revision 1. The objects are called
> `website` because the release name contains the chart name (see `website.fullname`).

Where does Helm keep the release? `oc get secret -l owner=helm` – one Secret per revision.

**If it does not work**

- `Error: INSTALLATION FAILED: cannot re-use a name that is still in use` – the release exists
  already. Use `helm upgrade website ./website` instead, or `helm uninstall website` first.
- `curl` returns `503` – the Pod is not ready yet: `oc get pods -l app.kubernetes.io/instance=website`.
- `helm install` installed into the wrong project – check `oc project -q`.

### 6 · Upgrade and roll back

**Goal:** change the release, see its history and go back.

```bash
helm upgrade website ./website --set replicaCount=3
oc get pods -l app.kubernetes.io/instance=website
helm get values website
helm history website
helm rollback website 1
helm history website
oc get pods -l app.kubernetes.io/instance=website
```

**What happens**

- `helm upgrade website ./website --set replicaCount=3` renders the chart with one value changed
  and applies the difference – the Deployment is scaled to three Pods. This is revision 2.
- `helm get values website` prints the values you passed for the current revision:
  `replicaCount: 3`.
- `helm history website` lists every revision with its status and description.
- `helm rollback website 1` applies the objects of revision 1 again – one replica. It creates a
  **new** revision 3 with the description `Rollback to 1`.

**Expected result:** after the upgrade three Pods; `helm history` shows revisions 1 and 2, then
1, 2 and 3; after the rollback one Pod again (the other two terminate).

> **What to notice:** every upgrade and rollback is a new **revision**. `helm get values`
> shows what you passed with `--set`. The rollback to revision 1 creates revision 3 –
> with one replica again.

Good to know: `--set` is not remembered for the next upgrade. `helm upgrade website ./website`
without `--set` uses the chart defaults again – that is why GitOps puts the values in a file.

## Done early? Bonus

- **Your own page:** the page comes from a ConfigMap, a checksum rolls the Pods when it changes.

  ```bash
  cp reference/bonus/configmap.yaml reference/bonus/deployment.yaml website/templates/
  helm upgrade website ./website --set message="Hello from $NS"
  ROUTE=$(oc get route website -o jsonpath='{.spec.host}')
  curl -k https://$ROUTE
  ```

  Run the upgrade again with the same message – do the Pods restart? And with a new one?
- **Package it:** `helm package website`, then `helm show chart website-0.1.0.tgz`.

Stuck? `reference/website/` is the finished chart: `helm upgrade --install website reference/website`

---

## Cleanup

The chart is not used again – lab 4 builds the same website with Kustomize, and its objects are
called `dev-website` and `prod-website`. Remove the release:

```bash
helm uninstall website
helm list
oc get deployment,service,route,configmap -l app.kubernetes.io/instance=website
```

**What happens:** `helm uninstall` deletes every object of the release – Helm knows them from the
release record (a Secret `sh.helm.release.v1.website.v…`), which it deletes as well. `helm list`
no longer shows `website`.

**Expected result:** `release "website" uninstalled`, an empty `helm list`, `No resources found`.

The chart folder `website/` stays on your machine – your work. If you want to run the lab again
from the start, remove it: `rm -rf website` (task 1 refuses to overwrite it).

> **What to notice:** one command, everything gone – because Helm tracks what it installed.
> Compare with lab 0, where you deleted every object by name.
