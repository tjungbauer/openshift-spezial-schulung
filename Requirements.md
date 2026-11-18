
---------------------------------------------------------------------------
Student requirements – please prepare before Day 1
---------------------------------------------------------------------------

Bring
  - your laptop with admin rights (or the tools below already installed)
  - a bash or zsh terminal (Windows: WSL2) and a current browser
  - your user name and password for OpenShift, the Git server and the Nexus registry

Install & verify
  - oc command line
  - helm command line
  - OPTIONAL: kustomize command line (bundled with oc) 
  - yq
  - jq
  - podman (or docker)
  - skopeo
  - git
  - kubeseal
  - check: oc version --client; helm version; git --version; podman --version

Network (from the laptop, also through the company proxy)
  - OpenShift API and console, and the Routes (*.apps.<cluster domain>)
  - the Git server and the image registry (Nexus)
  - registry.access.redhat.com (base images for the lab 1 build)
  - quay.io just in case to use predefined images

Check before the training
  - oc login works and you see your namespace sbx-wsXX
  - podman login <registry> works
  - you can log in to the Git web UI and have a token with write access
    (lab 5 and the Day 2 start create the empty repositories website-gitops and shop-gitops)
  - the training repository is cloned on your laptop

During the Labs:
  - You will get your own namespaces
     - sbx-wsXX
     - sbx-wsXX-neighbour
     - There should be no quotas

Export variables:
  - export REGISTRY=registry.acme.example
  - export REGISTRYORG=workshop

  # Git Repository: 
  - export NS=sbx-ws00                                                 # your namespace
  - export REPO_URL=https://git.acme.example/user-01/website-gitops.git   # your repository
  - export GIT_USER=user-01                                           # your Git user
  - export WORK=~/website-gitops  
