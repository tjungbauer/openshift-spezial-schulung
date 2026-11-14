# OpenShift Core Concepts – Interactive Demos

Guided demos for the OpenShift trainings (01–06 basics refresher, 10–12 advanced Day 1, 13– advanced Day 2; 08 and 09 use public charts on GitHub). Each demo folder has:

- an **interactive script** (`demo-0X-*.sh`) that the trainer runs live, step by step
- a **README** with the same steps written out, so students can repeat them by hand
- the **manifests** used in the demo

| # | Demo | Script | Topics |
|---|------|--------|--------|
| 01 | [Simple Pods](01_simple-pod/) | `demo-01-simple-pod.sh` | `oc run`, PodSecurity warning & securityContext, pod YAML, multi-container pods, QoS classes |
| 02 | [Projects & Namespaces](02_projects_namespaces/) | `demo-02-projects-namespaces.sh` | `oc status`, project vs. namespace, annotations, `oc new-project` |
| 03 | [ConfigMaps & Secrets](03_configmaps-secrets/) | `demo-03-configmaps-secrets.sh` | env vars, mounted files, base64, live updates |
| 04 | [Deployments](04_deployments/) | `demo-04-deployments.sh` | self-healing, scaling, rolling update, rollback, cascading delete |
| 05 | [Services & Routes](05_services_routes/) | `demo-05-services-routes.sh` | port-forward, Services, DNS, Routes, edge TLS |
| 06 | [Network isolation & egress](06_network_policies/) | `demo-06-network-policies.sh` | NetworkPolicy (default-deny, same-namespace, router, egress), EgressFirewall |
| 07 | [The shop – many containers, one application](07_multi-container/) | `demo-07-multi-container.sh` | the complete shop with one `oc apply -k`, walk-through in the browser, automatic cleanup |
| 10 | [The shop as a Helm chart](10_helm-shop/) | `demo-10-helm-shop.sh` | values per environment, checksum rollout, `fail`, hooks, `helm test`, rollback |
| 11 | [The shop with Kustomize](11_kustomize-shop/) | `demo-11-kustomize-shop.sh` | base, components, overlays, `oc diff -k`, own overlay |
| 12 | [An Argo CD Application](12_argocd-application/) | – (UI, `Application.yaml`) | Application form, sync policy, Helm values files, self heal |
| 13 | [Probes at work](13_probes/) | `demo-13-probes.sh` | readiness vs. liveness, startup probe for slow starters, wrong liveness path, stuck rollout |
| 14 | [Requests, limits and the HPA](14_resources-hpa/) | `demo-14-resources-hpa.sh` | requests vs. usage, CPU throttling, HPA scale-out, scale-in stabilisation |
| 15 | [From metric to alert](15_metrics-alerts/) | `demo-15-metrics-alerts.sh` | /metrics, ServiceMonitor, PromQL rate and histogram_quantile, PrometheusRule pending/firing |
| 16 | [One request, three signals](16_logs-traces/) | `demo-16-logs-traces.sh` | JSON logs, request id across web/orders/catalog, OpenTelemetry on with one env var, the trace in Jaeger |
| 22 | [Storage in action](22_storage/) | `demo-22-storage.sh` | PVC Pending → Bound, RWX on block storage, data outlives the Pod, RWO + RollingUpdate = Multi-Attach, snapshot and restore |

## Prerequisites

- `oc` CLI, logged in to a cluster (`oc login ...`)
- permission to create a project (or an existing project named `demo`)
- `bash` (3.2 or newer – the macOS default works) and `curl`
- optional: `yq` (mikefarah or python flavour) – demo 01 uses it to show `oc run --overrides` as YAML
- the cluster can pull `registry.redhat.io/ubi9/ubi`, `quay.io/nginx/nginx-unprivileged`
  and `nginxinc/nginx-unprivileged` (Docker Hub)

## Running a demo

```bash
cd demos/01_simple-pod
./demo-01-simple-pod.sh
```

Every script:

1. checks that you are logged in and prints cluster, user and project
2. **switches to the project `demo` – and creates it if it does not exist**
3. removes leftovers from a previous run of the same demo
4. walks through the demo:
   - each command is shown first and runs when you press **ENTER**
   - **`q` + ENTER** quits at any prompt
   - red boxes are discussion points – talk about them, then press ENTER
   - a failing command does not stop the demo (sometimes the error is the lesson)
5. on exit (end, `q` or Ctrl-C) asks whether to delete the demo's resources,
   then switches back to the project you were in before

The `demo` project itself is kept, so all demos share it. Remove it with
`oc delete project demo` when you are done.

### Options

All options are environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DEMO_PROJECT` | `demo` | project the demos run in (on a shared cluster: `DEMO_PROJECT=demo-$(oc whoami)`) |
| `DEMO_CLEANUP` | *(ask)* | `y` or `n` answers the cleanup question in advance |
| `DEMO_AUTO` | `0` | `1` runs without waiting for ENTER (dry runs, testing) |
| `DEMO_LABEL` | `openshift-example=yes` | label put on all demo objects |
| `DEMO_THEME_FILE` | `lib/theme.sh` | alternative colour theme |
| `NO_COLOR` | – | set to disable colours |

Example:

```bash
DEMO_PROJECT=demo-alice DEMO_CLEANUP=y ./demo-04-deployments.sh
```

### Command line options

Demos 01 and 06 also accept the namespace on the command line (this
overrides `DEMO_PROJECT`):

```bash
./demo-01-simple-pod.sh -n my-namespace     # or --namespace my-namespace
./demo-01-simple-pod.sh --help
```

Demo 06 can also run a single step or only the cleanup:

```bash
./demo-06-network-policies.sh 3             # only step 3
./demo-06-network-policies.sh cleanup
```

## Layout

```
demos/
├── README.md                  # this file
├── lib/
│   ├── theme.sh               # all colours – the only place they are defined
│   └── demo-lib.sh            # shared helpers, sourced by every demo script
├── 01_simple-pod/
│   ├── demo-01-simple-pod.sh
│   ├── README.md
│   └── *.yml
├── 02_projects_namespaces/
├── 03_configmaps-secrets/
├── 04_deployments/
├── 05_services_routes/
└── 06_network_policies/
```

## Writing a new demo

Create a folder, add a script, source the library and use its helpers:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
cd "${SCRIPT_DIR}"

cleanup() { delete_quietly pod my-pod; }

parse_demo_args "$@"                   # optional: -n/--namespace, -h/--help
require_oc_login                       # login check + switch to/create "demo"
cleanup                                # remove leftovers
on_exit_cleanup cleanup "Delete the demo pod? [y/N]"

title "Demo 07 – Something" "subtitle"
section "1 · First part"
comment "Explain what comes next"
run "oc apply -f my-pod.yml"
discuss "Talking point" "" "line 1" "line 2"
takeaways "point 1" "point 2"
```

| Helper | Purpose |
|--------|---------|
| `title "Title" "subtitle"` | opening box |
| `section "1 · Name"` | section banner |
| `comment "text"` | explanation before a command |
| `run "command"` | show the command, wait for ENTER, run it |
| `show_file path` | print a file with a header |
| `discuss "Title" "line" ...` | highlighted discussion box, then pause |
| `pause` | wait for ENTER |
| `takeaways "point" ...` | closing summary |
| `info` / `success` / `warn` / `die` | status messages |
| `ask "Question? [y/N]"` | yes/no question (returns 0 on yes) |
| `wait_until "desc" SECONDS "command"` | poll until the command succeeds |
| `parse_demo_args "$@"` | handle `-n/--namespace NAME` and `-h/--help`; positional arguments go to `DEMO_ARGS` if the script sets `DEMO_USAGE_ARGS` (see demo 06) |
| `yaml_to_json file` / `yq_to_json_cmd file` | convert YAML to compact JSON (e.g. for `oc run --overrides`) |
| `require_cmd name ...` | abort if a tool is missing |
| `require_oc_login` | login check, switch to `$DEMO_PROJECT` (create if needed) |
| `delete_quietly kind name ...` | delete in `$DEMO_PROJECT`, ignore missing objects |
| `on_exit_cleanup fn "Question?"` | ask on exit whether to run `fn` |
| `on_exit_always fn` | always run `fn` on exit (stop background processes, ...) |

To change colours, edit `lib/theme.sh` (or copy it and set `DEMO_THEME_FILE`).
Scripts use only the semantic names (`C_CMD`, `C_HEADING`, `C_DISCUSS_BG`, ...).
