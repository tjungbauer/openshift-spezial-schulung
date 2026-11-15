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

  Lab 05 --> MUST BE TESTED ON CUSTOMER ENV
  - welches GIT repo soll verwendet werden? URL bereitstellen
  - --> eventuell jeder sein eigenes repo ?
export NS=sbx-ws00                                                 # your namespace
export REPO_URL=https://git.acme.example/user-01/website-gitops.git   # your repository
export GIT_USER=user-01                                           # your Git user
export WORK=~/website-gitops  

--> muss vorbereitet sein, inkl Token

---------------------------------------------------------------------------
Student requirements – please prepare before Day 1
---------------------------------------------------------------------------

Bring
  - your laptop with admin rights (or the tools below already installed)
  - a bash or zsh terminal (Windows: WSL2) and a current browser
  - your user name and password for OpenShift, the Git server and the registry

Install
  - oc, helm, git (2.28 or newer), podman (or docker), skopeo, jq, yq, kubeseal
  - check: oc version --client; helm version; git --version; podman --version

Network (from the laptop, also through the company proxy)
  - OpenShift API and console, and the Routes (*.apps.<cluster domain>)
  - the Git server and the image registry (Nexus)
  - registry.access.redhat.com (base images for the lab 1 build)

Check before the training
  - oc login works and you see your namespace sbx-wsXX
  - podman login <registry> works
  - you can log in to the Git web UI and have a token with write access
    (lab 5 and the Day 2 start create the empty repositories website-gitops and shop-gitops)
  - the training repository is cloned on your laptop
