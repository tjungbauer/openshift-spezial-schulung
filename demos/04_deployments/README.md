# Demo 04 – Deployments

Deploy nginx with a Deployment and look at self-healing, scaling, rolling
updates, rollbacks and cascading deletes.

## Run the demo

```bash
./demo-04-deployments.sh
```

The script switches to the project `demo` (and creates it if needed), walks
through the steps below and offers to delete the deployment at the end. See
the [demos README](../README.md) for options.

To follow along by hand, start with:

```bash
oc new-project demo || oc project demo
```

## 1. Deploy nginx

Look at [nginx-deployment.yml](nginx-deployment.yml), then deploy it:

```bash
oc apply -f nginx-deployment.yml
oc rollout status deployment/nginx-deployment --timeout=120s
```

Which additional resources were created?

```bash
oc get deployment,replicaset,pod -l app=nginx,openshift-example=yes
```

Who owns the pod?

```bash
oc get pods -l app=nginx,openshift-example=yes \
  -o jsonpath='{range .items[*]}{.metadata.name} -> {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

> **Discuss:** Deployment (desired state + rollout strategy) → ReplicaSet
> (keeps exactly N pods) → Pod. You manage the Deployment, the rest is created
> for you.

## 2. Delete the pod

What happens if you delete the nginx pod?

```bash
oc get pods -l app=nginx,openshift-example=yes
oc delete pods -l app=nginx,openshift-example=yes
oc get pods -l app=nginx,openshift-example=yes
```

> **Discuss:** Self-healing – the ReplicaSet controller compares desired and
> actual state and immediately creates a replacement pod (with a new name).
> Never rely on a pod name or IP.

## 3. Scale the deployment to two

```bash
oc scale --replicas=2 deployment/nginx-deployment
oc rollout status deployment/nginx-deployment --timeout=120s
```

What is the state of the ReplicaSet now? How many pods are running?

```bash
oc get replicaset -l app=nginx,openshift-example=yes
oc get pods -l app=nginx,openshift-example=yes -o wide
```

`oc scale` changed the live object – the YAML file still says `replicas: 1`:

```bash
oc diff -f nginx-deployment.yml
```

## 4. Rolling update and rollback

Any change to the pod template triggers a new rollout:

```bash
oc set env deployment/nginx-deployment DEMO_VERSION=v2
oc rollout status deployment/nginx-deployment --timeout=120s
```

There are now two ReplicaSets – the old one is scaled to 0:

```bash
oc get replicaset -l app=nginx,openshift-example=yes
oc rollout history deployment/nginx-deployment
```

Go back to the previous revision:

```bash
oc rollout undo deployment/nginx-deployment
oc rollout status deployment/nginx-deployment --timeout=120s
oc get replicaset -l app=nginx,openshift-example=yes
```

> **Discuss:** With the default `RollingUpdate` strategy new pods start  
> before old ones stop – no downtime. Old ReplicaSets are kept  
> (`revisionHistoryLimit`) so `oc rollout undo` can switch back instantly.

## Cleanup

```bash
oc delete deployment nginx-deployment --ignore-not-found
```

## Key takeaways

- Deployments manage ReplicaSets, ReplicaSets manage pods
- Deleted pods are replaced automatically (self-healing)
- `oc scale` changes the replica count of the live object
- Template changes roll out; `oc rollout undo` rolls back
- Deleting a Deployment removes its ReplicaSets and pods
