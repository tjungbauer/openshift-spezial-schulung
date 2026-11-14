#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 01 – Build and publish like a pro: interactive walkthrough
#  Run:     DEV=... RELEASE=... ./lab-01-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, podman + skopeo logged in to the registry, jq, curl
#
#  Goes through the lab task by task (ENTER runs each command), the same way
#  as the demo scripts. Default namespace for task 6: lab.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-01-lib.sh
source "${SCRIPT_DIR}/lab-01-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus task
  cleanup                delete the lab objects and the local images

  DEV=IMAGE              dev image name without tag (required, or REGISTRY)
  RELEASE=IMAGE          release image name without tag (required, or REGISTRY)
  REGISTRY=HOST/ORG      shortcut: \$REGISTRY/shop-catalog-dev and \$REGISTRY/shop-catalog
  PULL_USER, PULL_TOKEN  pull secret for a private release repository (task 6)
  LAB_NS=NAME            same as -n NAME"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[1-6]|bonus|cleanup) ;;
  *) demo_usage >&2; die "Unknown task: ${MODE}" ;;
esac

lab_init

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [1-6])
    "task${MODE}"
    ;;
  bonus)
    bonus
    ;;
  all)
    on_exit_cleanup cleanup "Delete the lab objects in ${LAB_NS} and the local images? [y/N]"

    title "Lab 01 – Build and publish like a pro" \
          "multi-stage Python · tag + SHA · labels · push · promote by digest"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "Multi-stage: pip and build tools stay in the build stage" \
      "USER 1001 in the image – OpenShift runs a random UID, group 0" \
      "Tag = version + git SHA; the same string in labels and /info" \
      "skopeo inspects and copies without pulling" \
      "Promote by digest – release gets the tested bits" \
      "Deploy by digest – a moved tag cannot change what runs"

    if ask "Run the bonus task (build in the cluster) too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
