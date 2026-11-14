# Demo 05 – Services & Routes

A full example for exposing an application: nginx serving a page from a
ConfigMap, tested with port-forward, made reachable inside the cluster with a
Service and outside the cluster with Routes (plain HTTP and edge TLS).

## Run the demo

```bash
./demo-05-services-routes.sh
```

The script switches to the project `demo` (and creates it if needed), walks
through the steps below and offers to delete all resources at the end. The
port-forward runs in the background and is stopped automatically. See the
[demos README](../README.md) for options.

To follow along by hand, start with:

```bash
oc new-project demo || oc project demo
```

## 1. Create a ConfigMap from index.html

The ConfigMap holds the web page ([index.html](index.html)). We also label it
with `openshift-example=yes`:

```bash
oc create configmap index --from-file=index.html
oc label configmap index openshift-example=yes
```

## 2. Deploy nginx serving the ConfigMap

[nginx-deployment-cm.yml](nginx-deployment-cm.yml) mounts the ConfigMap to
`/usr/share/nginx/html`:

```bash
oc apply -f nginx-deployment-cm.yml
oc rollout status deployment/nginx-deployment --timeout=120s
oc get deployment,replicaset,pod -l app=nginx,openshift-example=yes
```

What kind of resources were created?

## 3. Test with oc port-forward

`oc port-forward` sits there without output and forwards the port. Run it in
the background (or use a second shell on the **same** machine):

```bash
export PORT="80$(( RANDOM % 89 + 10 ))"
oc port-forward deployment/nginx-deployment ${PORT}:8080 &
curl localhost:${PORT}
kill %1
```

> **Discuss:** port-forward tunnels a local port through the API server to
> *one* pod. Great for debugging, but not a way to expose an application – it
> only works while the command runs, only on your machine, without load
> balancing.

## 4. Create a Service

```bash
oc apply -f nginx-service.yml
oc get service nginx
oc get endpointslices -l kubernetes.io/service-name=nginx
```

Can you use curl to access the service from your machine? No – the
ClusterIP is reachable only inside the cluster:

```bash
oc get service nginx -o jsonpath='{.spec.clusterIP}{"\n"}'
```

So curl it from **inside** the cluster. [curl-pod.yml](curl-pod.yml) curls
`nginx.<namespace>.svc.cluster.local:8080` every second:

```bash
oc create -f curl-pod.yml
oc wait --for=condition=Ready pod/curl-pod --timeout=120s
oc logs --tail=5 curl-pod
```

> **Discuss:** Pods come and go and their IPs change. A Service gets a stable
> ClusterIP and DNS name and load-balances to all ready pods matching its
> selector.

## 5. What happens if the ConfigMap changes?

[manifests/index-cm.yaml](manifests/index-cm.yaml) contains a new page
("hello world 2"):

```bash
oc replace -f manifests/index-cm.yaml
```

The kubelet updates mounted ConfigMaps periodically. After up to about a
minute, the curl pod shows the new page – without restarting nginx:

```bash
oc logs --tail=5 curl-pod
```

## 6. Expose the service with a Route

```bash
oc expose service nginx
oc label route nginx openshift-example=yes --overwrite
```

What kind of resource was created?

```bash
oc get route
```

[nginx-route.yml](nginx-route.yml) is the declarative equivalent of
`oc expose`. Access nginx via the route:

```bash
curl -s http://$(oc get route nginx -o jsonpath='{.spec.host}')
```

## 7. Expose the service via a TLS edge route

```bash
oc create route edge nginx-ssl --service=nginx
oc label route nginx-ssl openshift-example=yes --overwrite
```

Look at the `TERMINATION` column and the details of the route:

```bash
oc get route
oc describe route nginx-ssl
```

Access nginx via the encrypted route (`-k`, because the router often uses the
cluster's self-signed default certificate):

```bash
curl -ks https://$(oc get route nginx-ssl -o jsonpath='{.spec.host}')
```

> **Discuss:** The OpenShift router (HAProxy) forwards external HTTP(S)
> traffic for a hostname to a Service. TLS termination types:
> **edge** (TLS ends at the router), **passthrough** (TLS goes straight to the
> pod), **reencrypt** (router terminates and re-encrypts to the pod).

## Cleanup

```bash
oc delete route nginx nginx-ssl --ignore-not-found
oc delete service nginx --ignore-not-found
oc delete pod curl-pod --ignore-not-found
oc delete deployment nginx-deployment --ignore-not-found
oc delete configmap index --ignore-not-found
```

## Key takeaways

- `oc port-forward` is for debugging only
- Services give pods a stable IP, DNS name and load balancing
- Mounted ConfigMap changes reach running pods automatically
- Routes expose services via the router: edge, passthrough, reencrypt
- `oc expose` / `oc create route` are shortcuts for Route YAML
