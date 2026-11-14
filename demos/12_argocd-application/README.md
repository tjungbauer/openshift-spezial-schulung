# Demo 12 – Create an Argo CD Application

Create the Application `hello-php` in the Argo CD UI of OpenShift GitOps – by hand, field by
field. Argo CD renders the Helm chart `hello-php-helm/hello-php` of
[openshift-basics](https://github.com/tjungbauer/openshift-basics) with `values-prod.yaml` and
syncs it into the namespace `hello-php-demo`.

There is nothing to automate: the demo is the form. `Application.yaml` is the same object –
use it to compare with **EDIT AS YAML**, or to create the Application without the UI.

Needs: access to the Argo CD UI (`openshift-gitops` instance) and permission to create
Applications in the namespace `openshift-gitops`.

## In the UI

| Step | Field | Value |
|---|---|---|
| 1 | Applications → **+ NEW APP** | |
| 2 | Application Name | `hello-php` |
| | Project Name | `default` |
| | Sync Policy | `Automatic` – tick **Prune Resources** and **Self Heal** |
| | Sync Options | tick **Auto-Create Namespace** |
| 3 | Repository URL | `https://github.com/tjungbauer/openshift-basics` |
| | Revision | `main` |
| | Path | `hello-php-helm/hello-php` |
| 4 | Cluster URL | `https://kubernetes.default.svc` |
| | Namespace | `hello-php-demo` |
| 5 | Helm → Values files | `values-prod.yaml` (if the section shows **Directory**, switch it to **Helm**) |
| 6 | **EDIT AS YAML** – compare with `Application.yaml`, then **CREATE** | |

Then open the app: resource tree, tab **PARAMETERS** (greeting `Hello from PROD`,
`replicaCount` 3), and the Route.

## What to show

- **Self heal:** scale the Deployment by hand – Argo CD sets it back to 3.

  ```bash
  oc scale deployment/hello-php --replicas=1 -n hello-php-demo
  oc get deployment hello-php -n hello-php-demo -w      # back to 3, then Ctrl-C
  ```

- **The path pitfall:** with path `hello-php-helm` (the parent folder) the app is
  Synced and Healthy – and has no resources.

## Without the UI

```bash
oc apply -f Application.yaml
oc get applications.argoproj.io hello-php -n openshift-gitops
oc get deployment,route -n hello-php-demo
```

## Cleanup

```bash
oc delete applications.argoproj.io hello-php -n openshift-gitops
oc delete project hello-php-demo
```

The Application has no deletion finalizer, so `oc delete` removes only the Application – the
objects stay; deleting the project removes them and the namespace that `CreateNamespace=true`
created. **DELETE** in the UI (cascade) removes the objects too, but not the namespace.
