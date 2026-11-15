#!/usr/bin/env bash
# Demo 18 – the cluster-admin part for ONE namespace (run once, as cluster-admin).
# The mesh is installed in ambient mode already (OSSM 3: Istio "default" and IstioCNI with
# profile ambient, ZTunnel, Kiali; OVN-Kubernetes routingViaHost: true). istiod only watches
# namespaces that match its discoverySelectors – on the training cluster the label
# istio-discovery=enabled.
#   ./admin/namespace-in-mesh.sh demo-mesh
set -euo pipefail
ns="${1:?usage: $0 NAMESPACE}"
oc get istio,istiocni,ztunnel
oc get istio default -o jsonpath='profile: {.spec.profile}{"\n"}discoverySelectors: {.spec.values.meshConfig.discoverySelectors}{"\n"}'
oc label namespace "${ns}" istio-discovery=enabled --overwrite
