# Demo 02 – Projects & Namespaces

What is the current project, how does a project differ from a namespace, and
which projects can I see?

## Run the demo

```bash
./demo-02-projects-namespaces.sh
```

The script switches to the project `demo` (and creates it if needed). If you
are allowed to create projects, it also creates a temporary project
`demo-02-tmp` and offers to delete it at the end. See the
[demos README](../README.md) for options.

To follow along by hand, start with:

```bash
oc new-project demo || oc project demo
```

## 1. Which project am I using?

`oc status` gives an overview of the current project:

```bash
oc status
```

Store the current project name in an environment variable:

```bash
export PROJECT=$(oc project -q)
echo ${PROJECT}
```

## 2. Project vs. namespace

Are there any annotations on your project?

```bash
oc describe project ${PROJECT}
```

What is the difference to a namespace?

```bash
oc describe namespace ${PROJECT}
oc get namespace ${PROJECT} -o jsonpath='{.metadata.annotations}' | tr ',' '\n'; echo
```

> **Discuss:** Every project *is* a namespace (same name, same object).
> OpenShift adds annotations such as `openshift.io/display-name`,
> `openshift.io/description`, `openshift.io/requester` and
> `openshift.io/sa.scc.uid-range` (the UIDs pods run with → SCCs).
> Projects are created from a ProjectRequest template, so admins can add
> quotas, limits, network policies and RBAC to every new project.

## 3. Projects: what am I allowed to see?

Projects list only the namespaces you have access to. Listing namespaces
needs cluster-wide permissions – as a normal user this is forbidden:

```bash
oc get projects
oc get namespaces
```

## Key takeaways

- Every OpenShift project is a Kubernetes namespace
- Projects add annotations: display name, requester, UID range
- Projects show only what you are allowed to see
- Use `oc project -q` in scripts to get the current project
