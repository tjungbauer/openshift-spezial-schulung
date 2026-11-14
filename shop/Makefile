# ACME shop – everyday commands. Every variable can be overridden:
#   make build VERSION=2.0.0
#   make push REGISTRY=nexus.acme.example:5000 IMAGE_PREFIX=workshop/shop-group1-
#   make check-images PODMAN="podman --connection podman-machine-default-root"
# The work is done by the scripts in scripts/ – read them, they are short.

VERSION       ?= $(shell cat VERSION)
REGISTRY      ?= quay.io/acme-workshop
IMAGE_PREFIX  ?= shop-
IMAGE_SUFFIX  ?=
IMAGE_TAG     ?= $(VERSION)
OVERLAY       ?= dev
NAMESPACE     ?=
SET_IMAGES    ?= false
RESTART       ?= false
PLATFORM      ?= linux/amd64
PODMAN        ?= podman
PIP_INDEX_URL ?= https://pypi.org/simple
ROUTE_URL     ?= http://localhost:8080

export VERSION REGISTRY IMAGE_PREFIX IMAGE_SUFFIX IMAGE_TAG OVERLAY NAMESPACE SET_IMAGES RESTART PLATFORM PODMAN PIP_INDEX_URL

.DEFAULT_GOAL := help
.PHONY: help build push run-local stop-local deploy test smoke validate check-images lint sync-common verify

help:  ## show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-14s %s\n", $$1, $$2}'

build:  ## build all images (linux/amd64, version + git revision)
	scripts/build.sh

push:  ## push to $(REGISTRY)/$(IMAGE_PREFIX)<service>$(IMAGE_SUFFIX):$(IMAGE_TAG) and verify
	scripts/push.sh

run-local:  ## run the whole shop in one podman pod – http://localhost:8080
	scripts/run-local.sh

stop-local:  ## stop the local pod
	scripts/run-local.sh down

deploy:  ## oc apply -k deploy/overlays/$(OVERLAY) into $(NAMESPACE) (default: current project)
	scripts/deploy.sh

test:  ## unit tests of all Python services
	scripts/test.sh

smoke:  ## end-to-end smoke test against ROUTE_URL (default: local pod)
	scripts/smoke.sh $(ROUTE_URL)

validate:  ## kustomize build + kubeconform for base, overlay and components
	scripts/validate.sh

check-images:  ## start every image as UID 1000680000:0 and check /health/ready
	scripts/check-images.sh

lint:  ## shellcheck all scripts
	shellcheck -x -P SCRIPTDIR scripts/*.sh

sync-common:  ## copy common/shopkit.py into every Python service
	scripts/sync-common.sh

verify: test lint validate  ## everything that needs no container runtime
