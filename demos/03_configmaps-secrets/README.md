# Demo 03 – ConfigMaps & Secrets

Configure an application with ConfigMaps and Secrets – as environment
variables and as mounted files – and see what happens when they change.

## Run the demo

```bash
./demo-03-configmaps-secrets.sh
```

The script switches to the project `demo` (and creates it if needed), walks
through the steps below and offers to delete the pod, ConfigMaps and Secret at
the end. See the [demos README](../README.md) for options.

To follow along by hand, start with:

```bash
oc new-project demo || oc project demo
```

## 1. The input files

- [run.sh](run.sh) – start script for the container: prints the config file
  and two environment variables every second
- [mainconfig.yml](mainconfig.yml), [anotherconfig.yml](anotherconfig.yml) –
  two configuration files

## 2. Create ConfigMaps

```bash
# from a file – the key is the file name (run.sh)
oc create configmap run --from-file=run.sh

# from two files – "configuration=" sets a custom key name
oc create configmap config --from-file=configuration=mainconfig.yml --from-file=anotherconfig.yml

# from a literal key=value
oc create configmap podenv --from-literal=variable=myvalue
```

Label them, so that `../../../utils/cleanup.sh` finds them later:

```bash
oc label configmap run config podenv openshift-example=yes
oc get configmaps -l openshift-example=yes
oc describe configmap config
```

Look at the keys of `config`: `configuration` and `anotherconfig.yml`.

## 3. Create a Secret

```bash
oc create secret generic geheim --from-literal=secret=nobody_knows
oc label secret geheim openshift-example=yes
```

The value is stored base64 encoded – which is **not** encryption:

```bash
oc get secret geheim -o yaml
oc get secret geheim -o jsonpath='{.data.secret}' | base64 -d; echo
oc extract secret/geheim --to=-
```

> **Discuss:** Anyone who may read a Secret can decode it. Protection comes
> from RBAC, etcd encryption at rest and external tools (Sealed Secrets,
> External Secrets, Vault). Never commit plain Secret YAML to Git.

## 4. The same objects as YAML

`--dry-run=client -o yaml` turns any `oc create` into a manifest:

```bash
oc create configmap podenv --from-literal=variable=myvalue --dry-run=client -o yaml
```

That is how the files in [manifests/](manifests/) were generated.

## 5. Use ConfigMaps and Secrets in a pod

Look at [not-so-simple-pod.yml](not-so-simple-pod.yml) and try to understand
how it works:

| In the container | Comes from |
|------------------|------------|
| env `VARIABLE` | ConfigMap `podenv`, key `variable` |
| env `SECRET` | Secret `geheim`, key `secret` |
| `/usr/local/bin/run.sh` | ConfigMap `run` (the container command) |
| `/etc/test/config.yml` | ConfigMap `config`, **only** key `configuration` |

`anotherconfig.yml` is in the ConfigMap but is **not** mounted.

```bash
oc apply -f not-so-simple-pod.yml
oc wait --for=condition=Ready pod/not-so-simple-pod --timeout=120s
oc logs --tail=6 not-so-simple-pod
oc exec not-so-simple-pod -- ls -l /etc/test/ /usr/local/bin/
oc exec not-so-simple-pod -- env | grep -E '^(VARIABLE|SECRET)='
```

## 6. What happens when a ConfigMap changes?

Change the mounted config file **and** the environment variable:

```bash
oc patch configmap config --type merge -p '{"data":{"configuration":"name: example\nversion: 0.9.9\n"}}'
oc patch configmap podenv --type merge -p '{"data":{"variable":"changed"}}'
```

The kubelet syncs mounted ConfigMaps periodically – wait up to about a
minute, then check the log again:

```bash
oc logs --tail=6 not-so-simple-pod
```

The config file shows `version: 0.9.9`, but `VARIABLE` still shows `myvalue`.

> **Discuss:** Mounted ConfigMaps/Secrets are updated in the running pod (not
> when mounted with `subPath`). Environment variables are set once, at
> container start – restart the pod (or roll out the Deployment) to pick up
> changes.

## Cleanup

```bash
oc delete pod not-so-simple-pod --ignore-not-found
oc delete configmap run config podenv --ignore-not-found
oc delete secret geheim --ignore-not-found
```

## Key takeaways

- ConfigMaps hold configuration, Secrets hold sensitive data
- Both can be used as environment variables or mounted files
- Secrets are only base64 encoded – protect them with RBAC
- `--dry-run=client -o yaml` generates manifests from `oc create`
- Mounted files update live, environment variables need a restart
