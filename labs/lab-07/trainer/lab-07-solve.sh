#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 07 – Break it – and watch it heal: automatic solution and checks
#  Run:     ./lab-07-solve.sh [-n|--namespace NAME] [TASK|bonus|check|cleanup]
#  Expects: oc logged in, git; GIT_REPO_URL, GIT_USERNAME, GIT_TOKEN
#
#     (no argument)   all tasks + checks
#     TASK            run only task n (1-6) – earlier tasks are filled in quietly
#     bonus           two replicas, one unready
#     check           PASS / FAIL per item (exit code = number of failures)
#     cleanup         delete what the lab created
#
#  Same tasks as lab-07-walkthrough.sh, but without pauses and discussions.
#  Check a student: LAB_NS=user-01 ./lab-07-solve.sh check
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_AUTO=1                       # no ENTER prompts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-07-lib.sh
source "${SCRIPT_DIR}/lab-07-lib.sh"

# automatic mode: commands and results only – no file listings, no discussions
show_file() { :; }
discuss()   { :; }
pause()     { :; }

DEMO_USAGE_ARGS="[TASK|bonus|check|cleanup]"
DEMO_USAGE_EXTRA="  (none)                 all tasks + checks
  TASK                   run only task n (1-6)
  bonus                  two replicas, one unready
  check                  PASS / FAIL per item (exit code = number of failures)
  cleanup                delete what the lab created

  LAB_NS=NAME            same as -n NAME
  GIT_REPO_URL=URL       HTTPS URL of the trainer's repository (force-pushed!)
  GIT_USERNAME, GIT_TOKEN  credentials for push and for Argo CD"
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
