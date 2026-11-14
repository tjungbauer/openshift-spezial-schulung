# Demo 01 – Simple Pods

Create pods from the command line and from YAML, understand (and fix) the
PodSecurity warning, run a pod with two containers and look at resource
requests, limits and QoS classes.

## Run the demo

```bash
./demo-01-simple-pod.sh                    # runs in the project "demo"
./demo-01-simple-pod.sh -n my-namespace    # runs in "my-namespace"
./demo-01-simple-pod.sh --help
```

| Option | Description |
|--------|-------------|
| `-n NAME`, `--namespace NAME`, `--namespace=NAME` | project/namespace to run the demo in (default: `demo`) |
| `-h`, `--help` | show usage |

The script:

1. switches to the project `demo` (or the one given with `-n`) and
   **creates it if it does not exist**
2. walks through the steps below – press ENTER to run each command,
   `q` + ENTER to quit
3. offers to delete the pods at the end and switches back to the project you
   were in before (the demo project itself is kept)

The namespace name must be a valid Kubernetes name (lowercase letters, digits
and `-`, max. 63 characters). `-n` overrides the `DEMO_PROJECT` environment
variable. See the [demos README](../README.md) for more options.

To follow along by hand, start with (replace `demo` if you use another name):

```bash
oc new-project demo || oc project demo
```

## 1. Check your current project

Before creating objects in OpenShift or Kubernetes, check which project
(namespace) you are using:

```bash
oc project
```

## 2. Create a pod from the command line

```bash
oc run -i -t ubi --image=registry.redhat.io/ubi9/ubi:9.9 --restart=Never --rm
```

- `-i` – run interactively
- `-t` – allocate a terminal
- `--restart=Never` – create a plain Pod and do not restart it
- `--rm` – delete the pod when the shell exits

Type `exit` to leave the shell. Because of `--rm`, the pod is gone:

```bash
oc get pods
```

> **Discuss:** `oc run` is quick but imperative – nothing is written down,
> so it is hard to reproduce. For anything you want to keep, use YAML.

## 3. What was that "PodSecurity" warning?

Creating the pod printed something like:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "ubi" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "ubi" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "ubi" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "ubi" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

> **Discuss:** **Pod Security Admission (PSA)** is the standard Kubernetes
> check. OpenShift labels every new project with `warn=restricted` and
> `audit=restricted`, so pods that do not set these four fields produce a
> warning:
>
> - `allowPrivilegeEscalation: false`
> - `capabilities.drop: ["ALL"]`
> - `runAsNonRoot: true`
> - `seccompProfile.type: RuntimeDefault`
>
> It is **only a warning** – PSA enforces nothing here (there is no `enforce`
> label). OpenShift's own **Security Context Constraints (SCC)** admit the pod:
> the default SCC `restricted-v2` fills in secure values (a non-root UID from
> the project's range, no capabilities, no privilege escalation).

The PSA labels OpenShift put on the project:

```bash
oc describe namespace demo | grep pod-security
```

```
pod-security.kubernetes.io/audit=restricted
pod-security.kubernetes.io/audit-version=latest
pod-security.kubernetes.io/warn=restricted
pod-security.kubernetes.io/warn-version=latest
```

Each label has the form `pod-security.kubernetes.io/<MODE>=<LEVEL>`:

| Mode | Effect when a pod violates the level |
|------|--------------------------------------|
| `enforce` | the pod is **rejected** |
| `audit` | allowed, the violation is recorded in the API audit log |
| `warn` | allowed, the user gets a warning (what we saw) |

| Level | Meaning |
|-------|---------|
| `privileged` | no restrictions |
| `baseline` | blocks known privilege escalations: `privileged: true`, `hostPath`, `hostNetwork`/`hostPID`/`hostIPC`, host ports, added capabilities, ... |
| `restricted` | baseline + hardening best practices: non-root, `allowPrivilegeEscalation: false`, drop `ALL` capabilities, seccomp `RuntimeDefault`, limited volume types |

`<MODE>-version` pins the rules of a level to a Kubernetes version (e.g.
`v1.33`), so that a cluster upgrade does not suddenly tighten them. `latest`
always uses the newest rules.

> **Discuss:** On OpenShift the **label syncer** sets `audit` and `warn`
> automatically, based on the SCCs that the project's service accounts may
> use. `enforce` is currently `privileged` cluster-wide – the SCCs do the
> actual enforcing. Changing these labels requires cluster-admin rights
> (`security.openshift.io/scc.podSecurityLabelSync=false` turns off the
> syncer for a namespace). Projects starting with `openshift-` are not synced.

**The fix:** set the four fields explicitly. As readable YAML, see
[ubi-security-overrides.yaml](ubi-security-overrides.yaml):

```yaml
spec:
  securityContext:                 # pod level
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: ubi                      # must match the pod name given to oc run
    securityContext:               # container level
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
```

`oc run --overrides` only accepts JSON, so convert the YAML on the fly with
`yq`. `--override-type=strategic` merges it into the generated pod, matching
containers by name. This time we also leave out `--rm`:

```bash
# mikefarah/yq
oc run -i -t ubi --image=registry.redhat.io/ubi9/ubi:9.9 --restart=Never \
  --override-type=strategic \
  --overrides="$(yq -o json -I0 ubi-security-overrides.yaml)"

# python-yq (jq wrapper) – use this line instead:
#   --overrides="$(yq -c . ubi-security-overrides.yaml)"
```

Without `yq`, pass the JSON directly:

```bash
oc run -i -t ubi --image=registry.redhat.io/ubi9/ubi:9.9 --restart=Never \
  --override-type=strategic \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"ubi","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

The demo script detects which `yq` is installed and shows the matching
command. Without `yq` it converts the file itself (python3 or ruby) and shows
the JSON.

No warning this time. After you exit, the pod is still there with status
`Completed` (no `--rm`). Check which SCC admitted it and what its
securityContext looks like now:

```bash
oc get pods
oc get pod ubi -o jsonpath='{.metadata.annotations.openshift\.io/scc}{"\n"}'
oc get pod ubi -o jsonpath='{.spec.securityContext}{"\n"}{.spec.containers[0].securityContext}{"\n"}'
oc delete pod ubi
```

> **Discuss:** **PSA** (Kubernetes) checks the spec you send against a
> profile (privileged / baseline / restricted). **SCC** (OpenShift) decides
> which pods may run *and* fills in defaults such as the UID. Set the
> securityContext explicitly in your manifests: no warnings, and the pod also
> runs on clusters that *enforce* `restricted`. From now on, the YAML files
> in this demo do exactly that.

## 4. Create a pod from a YAML file

Look at [simple-pod.yml](simple-pod.yml) – note the `securityContext` on the
pod level (`runAsNonRoot`, `seccompProfile`) and on the container level
(`allowPrivilegeEscalation`, `capabilities`):

```yaml
spec:
  securityContext:                 # pod level: applies to all containers
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: simple-pod
    ...
    securityContext:               # container level
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
```

Create the pod – there is no PodSecurity warning:

```bash
oc create -f simple-pod.yml
oc wait --for=condition=Ready pod/simple-pod --timeout=120s
oc get pods -o wide
oc logs simple-pod
```

`runAsNonRoot: true` works although the UBI image would run as root, because
the SCC assigns a UID from the project's range:

```bash
oc describe project demo | grep sa.scc.uid-range
oc exec simple-pod -- id
```

> **Discuss:** `apiVersion`/`kind` select the object type, `metadata` holds
> name and labels, `spec` describes the desired state.
> `oc create -f` fails if the object exists; `oc apply -f` creates *or*
> updates and is the preferred way to work with YAML.
>
> The UID range (e.g. `1000820000/10000`) means *first UID / number of UIDs*;
> every project gets its own block, and pods use the first UID by default.
> `gid=0` is normal: images make their files group-writable for the root
> group, so they work with any UID.

## 5. A pod running two containers

Look at [advanced-pod.yml](advanced-pod.yml). What do you see? (Every
container has its own container-level `securityContext`.)

```bash
oc create -f advanced-pod.yml
oc wait --for=condition=Ready pod/advanced-pod --timeout=120s
oc get pods
```

`READY` shows `2/2` – two containers in one pod. Without a container name,
`oc logs` uses the default container. Select a container with `-c`:

```bash
oc logs advanced-pod
oc logs -c container1 advanced-pod
oc logs -c container2 advanced-pod
```

Both containers share the pod's network – same IP, same hostname:

```bash
oc exec advanced-pod -c container1 -- cat /etc/hostname
oc exec advanced-pod -c container2 -- cat /etc/hostname
```

`advanced-pod` sets requests equal to limits for every container, so its QoS
class is `Guaranteed`. `simple-pod` sets no resources at all, so it is
`BestEffort`:

```bash
oc get pod advanced-pod -o jsonpath='{.status.qosClass}{"\n"}'
oc get pod simple-pod -o jsonpath='{.status.qosClass}{"\n"}'
```

> **Discuss:** Why put two containers into one pod (sidecars, init
> containers)? Requests are what the scheduler reserves, limits are the hard
> ceiling (CPU is throttled, memory → OOMKill). QoS decides the eviction
> order: Guaranteed > Burstable > BestEffort.

## Cleanup

```bash
oc delete pod simple-pod advanced-pod ubi --ignore-not-found
```

## Key takeaways

- Check your project before creating anything (`oc project`)
- `oc run` is quick but imperative – YAML is reproducible
- A pod can run several containers sharing network and volumes
- PodSecurity warnings: set the securityContext explicitly (SCC fills in the rest)
- Use `oc logs -c <container>` with multi-container pods
- Requests/limits decide scheduling and the QoS class
