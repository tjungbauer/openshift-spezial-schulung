#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 02 – Deploy the complete "shop": automatic solution and checks
#  Run:     ./lab-02-solve.sh [-n|--namespace NAME] [TASK|bonus|check|cleanup]
#  Expects: oc logged in, curl; a StorageClass with ReadWriteMany for task 5
#
#     (no argument)   all tasks + checks
#     TASK            run only task n (1-6)
#     bonus           delete postgres-0 / the orders Pod – data survives
#     check           PASS / FAIL per item (exit code = number of failures)
#     cleanup         delete the shop, PostgreSQL, the backup objects and the PVCs
#
#  Same tasks as lab-02-walkthrough.sh, but without pauses and discussions.
#  Default namespace: lab (created if missing, never deleted).
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_AUTO=1                       # no ENTER prompts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-02-lib.sh
source "${SCRIPT_DIR}/lab-02-lib.sh"

# automatic mode: commands and results only – no file listings, no discussions
show_file() { :; }
discuss()   { :; }
pause()     { :; }

DEMO_USAGE_ARGS="[TASK|bonus|check|cleanup]"
DEMO_USAGE_EXTRA="  (none)                 all tasks + checks
  TASK                   run only task n (1-6)
  bonus                  delete postgres-0 / the orders Pod – data survives
  check                  PASS / FAIL per item (exit code = number of failures)
  cleanup                delete the shop, PostgreSQL, the backup objects and the PVCs

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
