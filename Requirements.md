Requirements:
  - oc command line
  - helm command line
  - OPTIONAL: kustomize command line (bundled with oc) 
  - yq
  - jq
  - podman (or docker)
  - skopeo
  - git
  - kubeseal

Images/Registries: 
  - ....

OpenShift:
  URL: ...
  Login: ...

Namespaces:
  DEMOS
  -----
  - demo (automatisch angelegt, ansonsten via -n namespace mitgeben)
  - demo-other --> für Live Demo 06 und NetworkPolicy Demo

  LABS
  ----
  Lab 00
  - sbx-wsXX
  - sbx-wsXX-neighbour
- - KEINE QUOTAS

  Lab 01
  URL to Nexus and its ORG, Credentials must be available
  - export REGISTRY=registry.acme.example            # the registry
  - export REGISTRYORG=workshop

  Lab 02
  - PVC is required RWX