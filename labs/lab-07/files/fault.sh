#!/bin/sh
# Lab 7 – switch a fault on or off in EVERY catalog Pod:   ./files/fault.sh '{"error_rate": 0.3}'
# (lab 6's fault.sh switched one Pod – with the HPA there are two or more now).
# Calls POST /admin/fault inside each Pod (localhost) with the Pod's own ADMIN_TOKEN –
# no Route, no NetworkPolicy needed.
#   $1  JSON body, e.g. '{"error_rate": 0.3}', '{"error_rate": 0}', '{"delay_ms": 800}'
#   $2  optional: one Pod name (default: all running catalog Pods)
# Plain POSIX sh – works with ./files/fault.sh, bash files/fault.sh and sh files/fault.sh
# (on Debian/Ubuntu, sh is dash; on macOS, sh is bash).
set -eu
if [ $# -lt 1 ]; then
  echo "usage: $0 JSON [POD]" >&2
  exit 1
fi
if [ -n "${2:-}" ]; then
  pods="${2#pod/}"
else
  # all Running catalog Pods that are not terminating (no deletionTimestamp)
  pods="$(oc get pods -l app.kubernetes.io/name=catalog --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' \
    | awk 'NF == 1 { print $1 }')"
fi
if [ -z "${pods}" ]; then
  echo "no running catalog Pod found – are you in your shop namespace? (oc project)" >&2
  exit 1
fi
rc=0
for pod in ${pods}; do
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
' "$1" || rc=1
done
exit "${rc}"
