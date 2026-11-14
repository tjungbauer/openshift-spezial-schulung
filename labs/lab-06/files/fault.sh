#!/usr/bin/env bash
# Lab 6 – switch a fault on or off in a catalog Pod:   ./files/fault.sh '{"fail_ready": true}'
# Calls POST /admin/fault inside the Pod (localhost) with the Pod's own ADMIN_TOKEN –
# no Route, no NetworkPolicy, and it still works when the Pod is not ready.
#   $1  JSON body, e.g. '{"fail_ready": true}', '{"fail_ready": false}', '{"delay_ms": 500}'
#   $2  optional: a Pod name (default: the first Pod of deployment/catalog)
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 JSON [POD]" >&2; exit 1; }
target="${2:-deployment/catalog}"
# shellcheck disable=SC2016  # the Python code is for the container, not for bash
oc exec "${target}" -c catalog -- python3.12 -c '
import os, sys, urllib.request
req = urllib.request.Request("http://localhost:8080/admin/fault", data=sys.argv[1].encode(),
    method="POST", headers={"Content-Type": "application/json",
                            "Authorization": "Bearer " + os.environ.get("ADMIN_TOKEN", "")})
print(urllib.request.urlopen(req, timeout=5).read().decode())
' "$1"
