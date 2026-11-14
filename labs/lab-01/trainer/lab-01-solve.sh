#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 01 – Build and publish like a pro: automatic solution and checks
#  Run:     DEV=... RELEASE=... ./lab-01-solve.sh [-n|--namespace NAME] [TASK|bonus|check|cleanup]
#  Expects: oc logged in, podman + skopeo logged in to the registry, jq, curl
#
#     (no argument)   all tasks + checks
#     TASK            run only task n (1-6)
#     bonus           build in the cluster (binary BuildConfig)
#     check           PASS / FAIL per item (exit code = number of failures)
#     cleanup         delete the lab objects and the local images
#
#  Same tasks as lab-01-walkthrough.sh, but without pauses and discussions.
#  Default namespace for task 6: lab (created if missing, never deleted).
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_AUTO=1                       # no ENTER prompts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-01-lib.sh
source "${SCRIPT_DIR}/lab-01-lib.sh"

# automatic mode: commands and results only – no file listings, no discussions
show_file() { :; }
discuss()   { :; }
pause()     { :; }

DEMO_USAGE_ARGS="[TASK|bonus|check|cleanup]"
DEMO_USAGE_EXTRA="  (none)                 all tasks + checks
  TASK                   run only task n (1-6)
  bonus                  build in the cluster (binary BuildConfig)
  check                  PASS / FAIL per item (exit code = number of failures)
  cleanup                delete the lab objects and the local images

  DEV=IMAGE              dev image name without tag (required, or REGISTRY)
  RELEASE=IMAGE          release image name without tag (required, or REGISTRY)
  REGISTRY=HOST/ORG      shortcut: \$REGISTRY/shop-catalog-dev and \$REGISTRY/shop-catalog
  PULL_USER, PULL_TOKEN  pull secret for a private release repository (task 6)
  VERSION=X.Y.Z          version (default: 1.0.0)
  PLATFORM=OS/ARCH       build platform (default: linux/amd64)
  PIP_INDEX_URL=URL      PyPI mirror (Nexus) for the build
  LAB_NS=NAME            same as -n NAME"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[1-6]|bonus|check|cleanup) ;;
  *) demo_usage >&2; die "Unknown argument: ${MODE}" ;;
esac

lab_init

case "${MODE}" in
  all)
    for i in 1 2 3 4 5 6; do "task${i}"; done
    check
    ;;
  [1-6])   "task${MODE}" ;;
  bonus)   bonus ;;
  check)   check ;;
  cleanup) cleanup; success "Cleaned up." ;;
esac
