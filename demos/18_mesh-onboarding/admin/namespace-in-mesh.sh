#!/usr/bin/env bash
# Demo 18/19 – the cluster-admin part (run once, as cluster-admin).
# The mesh is installed in ambient mode already (OSSM 3: Istio "default" and IstioCNI with
# profile ambient, ZTunnel, Kiali; OVN-Kubernetes routingViaHost: true). istiod only watches
# namespaces that match its discoverySelectors – on the training cluster the label
# istio-discovery=enabled. Also creates the ztunnel PodMonitor (L4 metrics for Kiali).
#   ./admin/namespace-in-mesh.sh demo-mesh demo-traffic
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 NAMESPACE..." >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
oc get istio,istiocni,ztunnel
oc get istio default -o jsonpath='profile: {.spec.profile}{"\n"}discoverySelectors: {.spec.values.meshConfig.discoverySelectors}{"\n"}'
oc apply -f "${here}/ztunnel-podmonitor.yaml"
for ns in "$@"; do
  oc get namespace "${ns}" >/dev/null 2>&1 || oc new-project "${ns}" >/dev/null
  oc label namespace "${ns}" istio-discovery=enabled --overwrite
done
