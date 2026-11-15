#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 07 – Break it – and watch it heal: interactive walkthrough
#  Run:     ./lab-07-walkthrough.sh [-n|--namespace NAME] [TASK|slow|hpa|bonus|cleanup]
#  Expects: oc logged in, git; GIT_REPO_URL, GIT_USERNAME, GIT_TOKEN
#
#  Runs the commands of the student README (ENTER runs each command):
#  the shop from Git (Day 2 start, done quietly), auto-sync off, probes,
#  fail_ready, a wrong liveness path, the bonus tasks (slow start, HPA under
#  load), back to Git with auto-sync on. Default namespace: lab
#  (created with its own Argo CD; the shop runs in lab-shop). GIT_REPO_URL
#  must point to a repository the trainer owns – it is force-pushed.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-07-lib.sh
source "${SCRIPT_DIR}/lab-07-lib.sh"

DEMO_USAGE_ARGS="[TASK|slow|hpa|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6; 5 = both bonus tasks); default: all tasks
  slow                   run only bonus task 5a (a slow start)
  hpa                    run only bonus task 5b (scale on load)
  bonus                  run only the extra bonus (two replicas, one unready)
  cleanup                delete what the lab created

  LAB_NS=NAME            same as -n NAME
  WORK_DIR=PATH          where the repository is built (default: \${TMPDIR:-/tmp}/lab-07-<namespace>)
  GIT_REPO_URL=URL       HTTPS URL of the trainer's repository (force-pushed!)
  GIT_USERNAME, GIT_TOKEN  credentials for push and for Argo CD"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[1-6]|slow|hpa|bonus|cleanup) ;;
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
  slow|hpa)
    "task_${MODE}"
    ;;
  bonus)
    bonus
    ;;
  all)
    on_exit_cleanup cleanup "Delete the lab resources (${LAB_NS} and ${LAB_NS}-shop for the default namespace)? [y/N]"

    title "Lab 07 – Break it – and watch it heal" \
          "auto-sync off · probes · fail_ready · liveness · startup · HPA · back to Git"
    for i in 1 2 3 4; do "task${i}"; done
    if ask "Run the bonus tasks 5a (slow start) and 5b (HPA under load)? [y/N]"; then
      task5
    fi
    task6

    takeaways \
      "Readiness takes a Pod out of the Service – it does not restart it" \
      "A wrong liveness probe restarts a healthy app – keep it simple" \
      "The startup probe is the budget for a slow start" \
      "Readiness gates every rollout – the old version serves meanwhile" \
      "With an HPA, the replica count does not belong in Git" \
      "oc changes stay only while auto-sync is off – then back to Git"

    if ask "Run the extra bonus (two replicas, one unready) too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
