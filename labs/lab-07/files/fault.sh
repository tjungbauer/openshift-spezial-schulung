#!/usr/bin/env bash
# Lab 7 – switch a fault on or off in EVERY catalog Pod:   ./files/fault.sh '{"error_rate": 0.3}'
# (lab 6's fault.sh switched one Pod – with the HPA there are two or more now).
# Calls POST /admin/fault inside each Pod (localhost) with the Pod's own ADMIN_TOKEN –
# no Route, no NetworkPolicy needed.
#   $1  JSON body, e.g. '{"error_rate": 0.3}', '{"error_rate": 0}', '{"delay_ms": 800}'
#   $2  optional: one Pod name (default: all Pods of catalog)
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 JSON [POD]" >&2; exit 1; }
if [[ -n "${2:-}" ]]; then
  pods="pod/$2"
else
  pods="$(oc get pods -l app.kubernetes.io/name=catalog --field-selector=status.phase=Running -o name)"
fi
[[ -n "${pods}" ]] || { echo "no running catalog Pod found – are you in your shop namespace?" >&2; exit 1; }
for pod in ${pods}; do
  printf '%s  ' "${pod#pod/}"
  # shellcheck disable=SC2016  # the Python code is for the container, not for bash
  oc exec "${pod}" -c catalog -- python3.12 -c '
import os, sys, urllib.request
req = urllib.request.Request("http://localhost:8080/admin/fault", data=sys.argv[1].encode(),
    method="POST", headers={"Content-Type": "application/json",
                            "Authorization": "Bearer " + os.environ.get("ADMIN_TOKEN", "")})
print(urllib.request.urlopen(req, timeout=5).read().decode())
' "$1"
done
