#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 02 – Deploy the complete "shop": interactive walkthrough
#  Run:     ./lab-02-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, curl; a StorageClass with ReadWriteMany for task 5
#
#  Goes through the lab task by task (ENTER runs each command), the same way
#  as the demo scripts. Default namespace: lab.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-02-lib.sh
source "${SCRIPT_DIR}/lab-02-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus tasks
  cleanup                delete the shop, PostgreSQL, the backup objects and the PVCs

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
    on_exit_cleanup cleanup "Delete the shop, PostgreSQL, the backups and both PVCs in ${LAB_NS}? [y/N]"

    title "Lab 02 – Deploy the complete \"shop\"" \
          "StatefulSet · init container · CronJob · RWX volume"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "One Deployment + Service per component – web is the only way in" \
      "Optional services: the shop degrades, it does not crash" \
      "StatefulSet: stable name, own PVC, headless DNS per replica" \
      "Init container instead of depends_on – the Pod waits itself" \
      "CronJob -> Job -> Pod; RWX lets two Pods share one volume"

    if ask "Run the bonus tasks too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
