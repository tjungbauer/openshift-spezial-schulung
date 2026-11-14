# Lab 0 – Build it, expose it, close it (30 min)

Create a ConfigMap, a Secret, a Deployment, a Service and a Route yourself – then find out what
separates your namespace from your neighbour and close it with NetworkPolicies.

**You will learn**

- how configuration gets into a Pod – as environment variables and as files
- how to generate YAML instead of writing it from scratch
- how a Service and a Route make an application reachable – inside and outside the cluster
- that a namespace does **not** isolate network traffic – and how NetworkPolicies do

**How to work through this lab**

- Run every command from the folder `lab-00/` – the files used below are in it.
- Each task has the commands to copy, an explanation of what they do, the result to expect,
a **What to notice** box and a list of the most common problems.
- You may work in pairs for tasks 5 and 6: your neighbour tests your namespace and you test theirs.
- Stuck? `reference/deployment.yaml` is the finished Deployment of task 3. Ask the trainer for
anything else.

## Before you start

```bash
export NS=sbx-wsXX                      # your namespace – set it first
oc project $NS
export NEIGHBOUR=sbx-wsXX-neighbour     # the namespace of the person next to you
```

`oc project $NS` switches your current project – all `oc` commands below without `-n` work in
it. Check it any time with `oc project -q`. The variables only live in this terminal: open a new
terminal, set them again.

## Tasks

| # | Task | Time |
|---|---|---|
| 1 | Look around | 2 min |
| 2 | Configuration: ConfigMap and Secret | 4 min |
| 3 | Deployment that uses both | 7 min |
| 4 | Service and Route – then change the page | 5 min |
| 5 | Visit your neighbour | 3 min |
| 6 | Close your namespace | 7 min |
| 7 | Clean up | 2 min |

---

### 1 · Look around

**Goal:** see what limits and protects your project before you deploy anything.

```bash
oc describe project $NS
oc get quota,limitrange,networkpolicy
oc get serviceaccount,configmap,secret
```

**What happens**

- `oc describe project` shows the project's display name, its annotations – among them the UID
range OpenShift assigns to your Pods (`openshift.io/sa.scc.uid-range`) – and the quota and
limit range that apply to it.
- `oc get quota,limitrange,networkpolicy` lists the three kinds of objects that restrict a  
namespace.
- `oc get serviceaccount,configmap,secret` lists already available ServiceAccounts, ConfigMaps and Secretss

**Expected result:** depending on how the cluster is set up you see a ResourceQuota and a
LimitRange – or `No resources found`. You see **no NetworkPolicy**. At least 3 ServiceAccounts and some ConfigMaps and Secrets should be available already.

> **What to notice:** a ResourceQuota caps the total resources of your
> project, a LimitRange sets defaults per container. RBAC keeps your neighbour
> away from your objects – but there is no NetworkPolicy, so the **network** is
> open.

**If it does not work**

- `error: You are not a member of project "user-01"` – wrong namespace name in `NS`, or you are
logged in as another user: check with `oc whoami`.

---

### 2 · Configuration

**Goal:** put a web page into a ConfigMap and an API key into a Secret.

```bash
oc create configmap hello-page --from-file=index.html
oc create secret generic hello-secret --from-literal=API_KEY=s3cr3t
oc extract secret/hello-secret --to=-
```

**What happens**

- `--from-file=index.html` creates one key named after the file (`index.html`), with the file's
content as the value. Task 3 mounts it as a file into nginx.
- `--from-literal=API_KEY=s3cr3t` creates the Secret with one key, `API_KEY`. Task 3 turns it
into an environment variable.
- `oc extract --to=-` prints the decoded content of every key of the Secret to the terminal.

**Expected result**

```text
# API_KEY
s3cr3t
```

Look at both objects as YAML if you like: `oc get configmap hello-page -o yaml` shows the page in
clear text under `data`, `oc get secret hello-secret -o yaml` shows the key base64 encoded.

> **What to notice:** both keep configuration out of the image – same image
> everywhere, different configuration. The Secret is only base64 encoded:
> anyone who may read it can decode it.

**If it does not work**

- `error: failed to create configmap: configmaps "hello-page" already exists` – you ran it
before. Delete it (`oc delete configmap hello-page`) and create it again.
- `error reading index.html: no such file or directory` – you are not in `lab-00/`.

---

### 3 · Deployment

**Goal:** a Deployment that runs nginx, reads the API key from the Secret and serves the page
from the ConfigMap.

Generate the YAML, then add the two blocks below to the container and the Pod spec.

```bash
oc create deployment hello --image=quay.io/nginx/nginx-unprivileged:1.29.1 \
    --port=8080 --dry-run=client -o yaml > deployment.yaml
```

**What happens:** `--dry-run=client -o yaml` does not create anything – `oc` only prints the YAML
it *would* send, and `>` writes it into `deployment.yaml`. Open the file: a Deployment `hello`
with the label `app: hello`, one replica and one container listening on port 8080. The image
`nginx-unprivileged` runs without root and listens on 8080 – exactly what OpenShift's default
security settings expect.

Now open `deployment.yaml` in an editor and add these two blocks. **Indentation matters** – the
comments say where each block goes:

```yaml
        # under the container, next to ports:
        env:
        - name: API_KEY
          valueFrom:
            secretKeyRef: { name: hello-secret, key: API_KEY }
        volumeMounts:
        - { name: page, mountPath: /usr/share/nginx/html }
      # under spec.template.spec, next to containers:
      volumes:
      - name: page
        configMap: { name: hello-page }
```

- `env` with `secretKeyRef` sets the variable `API_KEY` from the key `API_KEY` of the Secret.
- `volumes` declares a volume `page` filled from the ConfigMap – every key becomes a file.
- `volumeMounts` puts that volume where nginx looks for its pages: `/usr/share/nginx/html`.
Your `index.html` replaces the nginx default page.

Optional: the generated YAML has no `securityContext`, so `oc apply` prints a
PodSecurity warning (the pod runs anyway – OpenShift's SCC makes it non-root).
To get rid of the warning, add:

```yaml
      # under spec.template.spec, next to containers:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
        # under the container, next to ports:
        securityContext:
          allowPrivilegeEscalation: false
          capabilities: { drop: [ALL] }
```

Apply the file, wait for the rollout and check the variable:

```bash
oc apply -f deployment.yaml
oc rollout status deploy/hello
oc exec deploy/hello -- printenv API_KEY
```

**Expected result:** `deployment "hello" successfully rolled out`, then `s3cr3t`.

Stuck? `reference/deployment.yaml` is the finished file (including the
`securityContext`).

> **What to notice:** `API_KEY` comes from the Secret as an environment
> variable (set once, when the container starts); `index.html` comes from the
> ConfigMap as a file in the nginx docroot. Generating YAML with
> `--dry-run=client -o yaml` and extending it is faster than writing it.

**If it does not work**

- `error converting YAML to JSON` or `unknown field` – an indentation problem. Compare your file
with `reference/deployment.yaml`.
- The Pod shows `CreateContainerConfigError` (`oc get pods`) – the Secret or a key name is wrong.
`oc describe pod -l app=hello` names the missing one.
- The rollout waits forever – `oc get pods` and `oc describe pod -l app=hello` show why
(image pull, quota exceeded, …).

---

### 4 · Service and Route

**Goal:** make the page reachable – inside the cluster with a Service, from your browser with a
Route – then change the page without a restart.

```bash
oc expose deployment hello --port=8080
oc create route edge hello --service=hello
ROUTE=$(oc get route hello -o jsonpath='{.spec.host}')
curl -k https://$ROUTE
```

**What happens**

- `oc expose deployment hello` creates a Service `hello` that selects the Pods by the
Deployment's label (`app: hello`) and forwards port 8080 to them.
- `oc create route edge` creates a Route: the OpenShift router accepts HTTPS for a generated host
name, ends TLS there (edge) and passes the request to the Service.
- `ROUTE=$(oc get route … -o jsonpath='{.spec.host}')` reads the generated host name into the
variable `ROUTE`; `curl -k https://$ROUTE` calls it (`-k`: accept the cluster's certificate even
if your machine does not trust it). `echo $ROUTE` shows the host name – open it in the browser.

> **zsh on macOS:** the commands read the host name into a variable (`ROUTE=$(…)`) first and
> use `https://$ROUTE` – zsh with oh-my-zsh escapes `(` after `https://` when you paste
> (`https://$\(oc …` → `parse error`). Keep that pattern when you write your own commands.

**Expected result:** the HTML of your `index.html` – `<h1>Hello from Lab 0</h1>`. Open the same
URL in your browser.

Now edit `index.html`, then update the ConfigMap – reload the page after a minute:

```bash
oc set data configmap/hello-page --from-file=index.html
```

`oc set data` replaces the key `index.html` of the ConfigMap with the new file. The kubelet on
the node notices the change and updates the mounted file – nginx serves the new page.

> **Note:** if your edited `index.html` contains non-ASCII characters
> (umlauts, `–`, emojis …), `oc set data` stores it under `binaryData`
> instead of `data`. The page still works, but `oc get configmap hello-page -o yaml`
> shows base64 under `binaryData`. Plain ASCII keeps it readable under `data`.

> **What to notice:** the Service gives the pods a stable name inside the
> cluster, the Route makes it reachable from outside via HTTPS (edge: TLS ends
> at the router). The changed page appears **without a restart** – the kubelet
> updates mounted ConfigMaps.

**If it does not work**

- `curl` returns `503` – the router finds no ready Pod: `oc get pods`, `oc get endpoints hello`.
- The old page stays – wait up to a minute (the kubelet syncs periodically), then reload.
Environment variables would **not** change without a restart; mounted files do.
- `curl: (6) Could not resolve host` – the host name was empty: check `oc get route hello` and
`echo $ROUTE`.
- `zsh: parse error near ')'` – you pasted `https://$(…)` into zsh. Use the two lines above:
`ROUTE=$(…)` first, then `https://$ROUTE`.

---

### 5 · Visit your neighbour

**Goal:** prove that a Pod in **another** namespace can reach your application – a namespace is
not a network boundary.

You have two namespaces: `$NS` with your app, and `$NEIGHBOUR` (e.g. `sbx-ws01-neighbour`). Treat
`$NEIGHBOUR` as the project of another team. You start one toolbox Pod in **each** namespace and
call your app from both:

```text
$NEIGHBOUR  (sbx-wsXX-neighbour)                     $NS  (sbx-wsXX)
  toolbox ── curl http://hello.$NS.svc:8080 ──▶       Service hello → Pod hello
                                                      toolbox ── curl http://hello:8080 ──▶ (same namespace)
```

```bash
oc apply -f toolbox.yaml
oc apply -n $NEIGHBOUR -f toolbox.yaml
oc wait --for=condition=Ready pod/toolbox --timeout=120s
oc wait -n $NEIGHBOUR --for=condition=Ready pod/toolbox --timeout=120s
oc exec toolbox -- curl -s -m 3 http://hello:8080
oc -n $NEIGHBOUR exec toolbox -- getent hosts hello.$NS.svc
oc -n $NEIGHBOUR exec toolbox -- curl -s -m 3 http://hello.$NS.svc:8080
```

**What happens**

- `toolbox.yaml` starts a small UBI Pod that only sleeps – a place inside the cluster with `curl`
and `getent`. The first `oc apply` creates it in your current project (`$NS`), the second with
`-n $NEIGHBOUR` in the other namespace. Both stay: task 6 uses them.
- `oc wait` blocks until each Pod is ready.
- `oc exec toolbox -- curl http://hello:8080` calls your app from **inside** your own namespace –
the short Service name is enough there.
- `oc -n $NEIGHBOUR exec toolbox -- …` runs the command in the toolbox of the **other** namespace.
`getent hosts` asks the cluster DNS for `hello.$NS.svc` – the answer is the Service's cluster
IP. `curl` calls your app by that name; `-m 3` gives up after three seconds.

**Expected result**

- Both `curl` commands print the HTML of your `index.html`.
- `getent hosts` prints one IP address and the name `hello.<your namespace>.svc.cluster.local`.

> **What to notice:** the short name `hello` only works inside the same namespace – from
> anywhere else you use `<service>.<namespace>.svc`. And it just works: without
> NetworkPolicies every Pod in the cluster reaches every Service in every namespace. RBAC decides
> who may **see and change** your objects – it does not stop anyone from **calling** your app.

**If it does not work**

- `Error from server (Forbidden)` on the `-n $NEIGHBOUR` commands – check the name
(`echo $NEIGHBOUR`) and that you have access: `oc get pods -n $NEIGHBOUR`.
- `getent hosts` prints nothing – there is no Service `hello` in `$NS`: check `echo $NS` and
`oc get service hello` (task 4).
- `curl` returns after 3 s without output – the Pod is not ready (`oc get pods`), or a
NetworkPolicy already blocks it: `oc get networkpolicy` should still be empty.

---

### 6 · Close your namespace – test after each step

**Goal:** lock your namespace and open exactly what is needed: your own Pods and the router.

Apply the three policies **one by one** and run the three tests below after each of them:

```bash
oc apply -f default-deny.yaml
oc apply -f allow-same-namespace.yaml
oc apply -f allow-from-router.yaml
```

The policies go into `$NS` – your current project. `$NEIGHBOUR` stays as it is.

What the three files do (look at them with `cat`):

| File | Selects | Allows in |
|---|---|---|
| `default-deny.yaml` | every Pod (`podSelector: {}`) | nothing – no ingress rule |
| `allow-same-namespace.yaml` | every Pod | Pods of the same namespace |
| `allow-from-router.yaml` | every Pod | the OpenShift router – its namespace carries the label `policy-group.network.openshift.io/ingress` |

All three tests call **your** app – from three places:

```bash
# 1. the toolbox in $NS → your app
oc exec toolbox -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://hello:8080
# 2. the Route, from your machine
ROUTE=$(oc get route hello -o jsonpath='{.spec.host}')
curl -sk -o /dev/null -w '%{http_code}\n' https://$ROUTE
# 3. the toolbox in $NEIGHBOUR → your app
oc -n $NEIGHBOUR exec toolbox -- curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://hello.$NS.svc:8080
```

`-o /dev/null -w '%{http_code}\n'` throws the page away and prints only the HTTP status code.

**Expected result**

| After | 1 · toolbox in `$NS` | 2 · Route | 3 · toolbox in `$NEIGHBOUR` |
|---|---|---|---|
| `default-deny.yaml` | blocked | 503 | blocked |
| `+ allow-same-namespace.yaml` | 200 | 503 | blocked |
| `+ allow-from-router.yaml` | 200 | 200 | blocked |

"blocked" shows up as `000` – curl gives up after `-m 3` seconds without an
answer. The Route answers `503` because the router itself cannot reach the pod.

```bash
oc get networkpolicy
```

> **What to notice:** `default-deny` locks out everybody – even the router.
> Policies are additive allow-lists: `allow-same-namespace` lets your own pods
> back in, `allow-from-router` the Route. The other namespace stays out.

Review the YAML specification

```bash
oc get networkpolicy -o yaml
```

**If it does not work**

- The results lag behind – policies take a few seconds to apply. Run the test again.
- Test 3 still `200` after `default-deny.yaml` – the policy went into the wrong namespace:
`oc get networkpolicy -n $NS` must list it (and `oc get networkpolicy -n $NEIGHBOUR` must not).
- The Route stays at `503` after `allow-from-router.yaml` – check the Pod is ready (`oc get pods`)
and that the file was applied (`oc get networkpolicy`).

---

### 7 · Clean up

**Goal:** leave both namespaces empty – the next labs start in `$NS` again, and a forgotten
`default-deny` would block them.

```bash
oc delete networkpolicy default-deny allow-same-namespace allow-from-router
oc delete route/hello service/hello deployment/hello configmap/hello-page secret/hello-secret
oc delete pod toolbox
oc delete pod toolbox -n $NEIGHBOUR
git restore deployment.yaml index.html
```

**What happens**

- The three NetworkPolicies go first – your namespace is open again, as at the start of the lab.
- The second command deletes the app: Route, Service, Deployment (and with it the ReplicaSet and
the Pod), the ConfigMap and the Secret.
- The two toolbox Pods – one in each namespace. `sleep` ignores the stop signal, so each delete
waits for the grace period of 30 seconds.
- `git restore` puts `deployment.yaml` (task 3) and `index.html` (task 4) back to the version in
the repository – the next person who runs the lab finds the original files.

Check that nothing of the lab is left:

```bash
oc get deployment,service,route,pod,networkpolicy
oc get configmap hello-page secret hello-secret
oc get pod -n $NEIGHBOUR
```

**Expected result:** `No resources found` for the first and the last command; the second one
answers `Error from server (NotFound)` for both objects. The ConfigMaps and Secrets you saw in
task 1 (`kube-root-ca.crt`, the service account tokens …) stay – they belong to the
project.

> **What to notice:** deleting the Deployment deletes what it owns – ReplicaSet and Pods. The
> Service, the Route, the ConfigMap and the Secret are separate objects: nobody deletes them for
> you. That is one reason why the following labs deploy with Kustomize, Helm and Argo CD – they
> know which objects belong to an application.

**If it does not work**

- `Error from server (NotFound)` for some objects – they were already gone (or never created);
nothing to do.
- `git restore` answers `not a git repository` – you are not in your clone of the training
repository; copy the two files from a fresh clone instead, or skip the step.
