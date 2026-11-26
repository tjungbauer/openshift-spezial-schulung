#!/bin/sh
# Lab 6 – switch a fault on or off in a catalog Pod:   ./files/fault.sh '{"fail_ready": true}'
# Calls POST /admin/fault inside the Pod (localhost) with the Pod's own ADMIN_TOKEN –
# no Route, no NetworkPolicy, and it still works when the Pod is not ready.
#   $1  JSON body, e.g. '{"fail_ready": true}', '{"fail_ready": false}', '{"delay_ms": 500}'
#   $2  optional: a Pod name (default: the first running catalog Pod)
# Plain POSIX sh – works with ./files/fault.sh, bash files/fault.sh and sh files/fault.sh
# (on Debian/Ubuntu, sh is dash; on macOS, sh is bash).
set -eu
if [ $# -lt 1 ]; then
  echo "usage: $0 JSON [POD]" >&2
  exit 1
fi
if [ -n "${2:-}" ]; then
  pod="${2#pod/}"
else
  # first Running catalog Pod that is not terminating (no deletionTimestamp)
  pod="$(oc get pods -l app.kubernetes.io/name=catalog --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk 'NF == 1 { print $1; exit }')"
fi
if [ -z "${pod}" ]; then
  echo "no running catalog Pod found – are you in your shop namespace? (oc project)" >&2
  exit 1
fi
printf '%s  ' "${pod}"
# shellcheck disable=SC2016  # the Python code is for the container, not for the shell
oc exec "${pod}" -c catalog -- python3.12 -c '
import os, sys, urllib.error, urllib.request
req = urllib.request.Request("http://localhost:8080/admin/fault", data=sys.argv[1].encode(),
    method="POST", headers={"Content-Type": "application/json",
                            "Authorization": "Bearer " + os.environ.get("ADMIN_TOKEN", "")})
try:
    print(urllib.request.urlopen(req, timeout=5).read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode())
    sys.exit(1)
' "$1"
