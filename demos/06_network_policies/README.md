# Demo 06 – Network isolation and egress

Projects separate names, RBAC and quotas – but not network traffic. This demo
closes a project step by step with NetworkPolicies, opens it again for the
router, restricts egress, and (as cluster-admin) controls external targets with
an EgressFirewall. It goes with the slides "Isolation has layers",
"Network isolation – who decides what?" and the egress slides.

## Run the demo

```bash
./demo-06-network-policies.sh                  # all steps, in the project "demo"
./demo-06-network-policies.sh -n my-namespace  # all steps, in "my-namespace"
./demo-06-network-policies.sh 3                # only step 3
./demo-06-network-policies.sh cleanup          # remove everything the demo created
./demo-06-network-policies.sh --help
```

| Option / argument | Description |
|-------------------|-------------|
| `-n NAME`, `--namespace NAME` | project to run the demo in (default: `demo`, created if missing) |
| `STEP` | run only this step (`0`–`6`); steps build on each other |
| `cleanup` | delete all demo resources |
| `OTHER_NS=NAME` (env) | the neighbour project (default: `<namespace>-other`) |

The script:

1. switches to the project `demo` (or the one given with `-n`), **creating it
   if needed**, and creates the neighbour project `demo-other` with
   `oc new-project --skip-config-write` (you stay in `demo`)
2. walks through the steps below – press ENTER to run each command,
   `q` + ENTER to quit
3. after every change tests who can reach the web app and compares the result
   with the expected one (`✔ as expected` / `✘ expected …`)
4. asks at the end (or on abort) whether to delete the demo resources –
   **say yes**: `default-deny` would otherwise block the other demos in the
   same project. The neighbour project is deleted only if the demo created it.

If self-provisioning is disabled, use an existing project as neighbour:

```bash
OTHER_NS=user-02 ./demo-06-network-policies.sh
```

## Expected results

| Step | What you show | Own client → web | Neighbour → web | Route |
|------|---------------|------------------|-----------------|-------|
| 1 | no NetworkPolicy | 200 | 200 | 200 |
| 2 | `np-default-deny.yaml` | blocked | blocked | **503** |
| 3 | `np-allow-same-namespace.yaml` | 200 | blocked | 503 |
| 4 | `np-allow-from-router.yaml` | 200 | blocked | 200 |
| 5 | `np-client-egress.yaml` | web 200 · access.redhat.com blocked – DNS still resolves | | |
| 6 | `egressfirewall.yaml` – **cluster-admin only** | access.redhat.com ok · www.google.com blocked · web 200 | | |

## Follow along by hand

```bash
oc new-project demo || oc project demo
oc new-project demo-other --skip-config-write
```

A quick way to test from a client pod (`000` = blocked):

```bash
oc -n demo       exec client -- curl -s -o /dev/null -m 4 -w '%{http_code}\n' http://web.demo.svc:8080
oc -n demo-other exec client -- curl -s -o /dev/null -m 4 -w '%{http_code}\n' http://web.demo.svc:8080
curl -sk -o /dev/null -w '%{http_code}\n' https://$(oc get route web -o jsonpath='{.spec.host}')
```

### 0. Setup

[app.yaml](app.yaml) – Deployment, Service and edge Route `web` (nginx);
[client.yaml](client.yaml) – a pod with `curl`, created in both projects.
Both set a restricted `securityContext` (see demo 01), so there are no
PodSecurity warnings.

```bash
oc apply -f app.yaml -f client.yaml
oc -n demo-other apply -f client.yaml
oc rollout status deployment/web --timeout=120s
oc wait --for=condition=Ready pod/client --timeout=120s
oc -n demo-other wait --for=condition=Ready pod/client --timeout=120s
```

### 1. No NetworkPolicy: everybody reaches everybody

```bash
oc get networkpolicy
```

> **Discuss:** Without NetworkPolicies the pod network is flat – every pod
> reaches every other pod, across all projects. Isolation has layers: RBAC,
> SCC, quotas … and NetworkPolicy for traffic.

### 2. default-deny: the project is closed – for everyone

```bash
oc apply -f np-default-deny.yaml
```

> **Discuss:** `podSelector: {}` with no ingress rules denies all ingress. As
> soon as *any* policy selects a pod, only explicitly allowed traffic gets in
> – policies are additive allow-lists. Even the router is locked out, so the
> Route answers **503**.

### 3. allow-same-namespace: own pods yes, the neighbour no

```bash
oc apply -f np-allow-same-namespace.yaml
```

> **Discuss:** A `podSelector` without `namespaceSelector` means pods of the
> *same* namespace. The router lives in another namespace – still 503.

### 4. allow-from-router: the Route works again

```bash
oc apply -f np-allow-from-router.yaml
oc get networkpolicy
```

> **Discuss:** OpenShift labels the namespace(s) of the ingress routers with
> `policy-group.network.openshift.io/ingress` – also when the routers run in
> host network. A typical baseline for every project: default-deny +
> allow-same-namespace + allow-from-router (+ allow-from-openshift-monitoring
> if you expose metrics).

### 5. Egress NetworkPolicy: DNS and the web app – nothing else

```bash
oc exec client -- curl -s -o /dev/null -m 4 -w '%{http_code}\n' https://access.redhat.com   # before: works
oc apply -f np-client-egress.yaml
oc exec client -- curl -s -o /dev/null -m 4 -w '%{http_code}\n' https://access.redhat.com   # after: 000
oc exec client -- getent hosts access.redhat.com                                            # DNS still works
```

> **Discuss:** Egress rules restrict what the *selected* pods may connect to.
> Once egress is restricted, DNS must be allowed explicitly – port 53 (Service)
> **and** 5353 (DNS pods), because NetworkPolicy sees the pod port after the
> Service DNAT. NetworkPolicy knows pods, namespaces and IP blocks, but no DNS
> names – for that there is the EgressFirewall.

### 6. EgressFirewall (cluster-admin only)

Skipped automatically if `oc auth can-i create egressfirewalls.k8s.ovn.org`
says no.

```bash
oc delete networkpolicy client-egress
oc apply -f egressfirewall.yaml
oc get egressfirewall
```

> **Discuss:** One EgressFirewall per namespace, always named `default`; rules
> by CIDR or DNS name, first match wins; it only applies to traffic *leaving*
> the cluster (web still answers). It is created by cluster-admins, so the
> project team cannot loosen it. NetworkPolicy = project team, pod level;
> EgressFirewall = platform team, external targets.

## Cleanup

```bash
./demo-06-network-policies.sh cleanup
```

or by hand:

```bash
oc delete egressfirewall default --ignore-not-found          # cluster-admin
oc delete networkpolicy default-deny allow-same-namespace allow-from-router client-egress --ignore-not-found
oc delete route,service,deployment web --ignore-not-found
oc delete pod client --ignore-not-found
oc delete project demo-other
```

`oc delete all,networkpolicy -l openshift-example=yes` removes everything labelled
`openshift-example=yes`, but not the EgressFirewall or the neighbour project.

## Notes

- Steps 5 and 6 need internet access from the cluster. In a disconnected
  cluster, change `EXTERNAL_OK` / `EXTERNAL_DENIED` in the script (and
  `egressfirewall.yaml`) to two hosts the cluster can reach.
- `access.redhat.com` is served by a CDN with changing IPs. EgressFirewall
  `dnsName` rules follow DNS, but if the pod and OVN resolve different IPs, the
  allowed host can briefly show as blocked – just run step 6 again.
- EgressIP is not part of the demo: it needs egress-assignable nodes and free
  IPs from the platform team.

## Key takeaways

- Projects do not isolate network traffic – NetworkPolicies do
- Start with default-deny, then allow what is needed
- Allow the router namespace, or Routes answer 503
- Egress policies need an explicit DNS rule (53 + 5353)
- EgressFirewall: platform-owned control of external targets
