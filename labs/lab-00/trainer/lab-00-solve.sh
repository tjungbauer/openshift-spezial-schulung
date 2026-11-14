#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 00 – Build it, expose it, close it: automatic solution and checks
#  Run:     ./lab-00-solve.sh [-n|--namespace NAME] [setup|TASK|bonus|check|cleanup]
#  Expects: oc logged in, curl
#
#     (no argument)   setup + all tasks + checks
#     setup           make sure both namespaces exist
#     TASK            run only task n (1-6)
#     bonus           headless + NodePort Service, Route timeout
#     check           PASS / FAIL per item (exit code = number of failures)
#     cleanup         delete what the lab created
#
#  Same tasks as lab-00-walkthrough.sh, but without pauses and discussions.
#  Default namespaces: lab and lab-neighbour (created, deleted by cleanup).
#  The second namespace defaults to <LAB_NS>-neighbour.
#  Check a student: LAB_NS=sbx-ws01 ./lab-00-solve.sh check
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_AUTO=1                       # no ENTER prompts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-00-lib.sh
source "${SCRIPT_DIR}/lab-00-lib.sh"

# automatic mode: commands and results only – no file listings, no discussions
show_file() { :; }
discuss()   { :; }
pause()     { :; }

DEMO_USAGE_ARGS="[setup|TASK|bonus|check|cleanup]"
DEMO_USAGE_EXTRA="  (none)                 setup + all tasks + checks
  setup                  make sure both namespaces exist
  TASK                   run only task n (1-6)
  bonus                  headless + NodePort Service, Route timeout
  check                  PASS / FAIL per item (exit code = number of failures)
  cleanup                delete what the lab created

  NEIGHBOUR_NS=NAME      the second namespace (default: <LAB_NS>-neighbour)
  LAB_NS=NAME            same as -n NAME"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|setup|[1-6]|bonus|check|cleanup) ;;
  *) demo_usage >&2; die "Unknown argument: ${MODE}" ;;
esac

lab_init

case "${MODE}" in
  all)
    setup_neighbour
    for i in 1 2 3 4 5 6; do "task${i}"; done
    check
    ;;
  setup)   setup_neighbour ;;
  [1-6])   "task${MODE}" ;;
  bonus)   bonus ;;
  check)   check ;;
  cleanup) cleanup; success "Cleaned up." ;;
esac
