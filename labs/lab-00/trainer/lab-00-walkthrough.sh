#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 00 – Build it, expose it, close it: interactive walkthrough
#  Run:     ./lab-00-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, curl
#
#  Goes through the lab task by task (ENTER runs each command), the same way
#  as the demo scripts. Default namespaces: lab and lab-neighbour (created).
#  In a student's namespaces: ./lab-00-walkthrough.sh -n sbx-ws01
#  (the second namespace defaults to sbx-ws01-neighbour)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-00-lib.sh
source "${SCRIPT_DIR}/lab-00-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus tasks
  cleanup                delete what the lab created

  NEIGHBOUR_NS=NAME      the second namespace (default: <LAB_NS>-neighbour)
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
    on_exit_cleanup cleanup "Delete the lab resources (${LAB_NS}, ${NEIGHBOUR_NS})? [y/N]"

    title "Lab 00 – Build it, expose it, close it" \
          "ConfigMap · Secret · Deployment · Route · NetworkPolicy"
    setup_neighbour
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "ConfigMaps and Secrets keep configuration out of the image" \
      "Generate YAML with --dry-run=client -o yaml, then extend it" \
      "Service = stable name inside, Route = HTTPS from outside" \
      "Namespaces do not isolate the network – NetworkPolicies do" \
      "default-deny + same-namespace + router = a closed project"

    if ask "Run the bonus tasks too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
