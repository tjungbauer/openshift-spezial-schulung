#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 07 – Metrics, alerts and logs: interactive walkthrough
#  Run:     ./lab-07-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, git; GIT_REPO_URL, GIT_USERNAME, GIT_TOKEN
#
#  Runs the commands of the student README (ENTER runs each command):
#  the shop from Git (Day 2 and lab 6 state, done quietly), ServiceMonitors,
#  up, PromQL, a PrometheusRule via Git, an alert that fires, the log lines
#  behind it. Default namespace: lab
#  (created with its own Argo CD; the shop runs in lab-shop). GIT_REPO_URL
#  must point to a repository the trainer owns – it is force-pushed.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-07-lib.sh
source "${SCRIPT_DIR}/lab-07-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus task (the slow alert)
  cleanup                delete what the lab created

  LAB_NS=NAME            same as -n NAME
  WORK_DIR=PATH          where the repository is built (default: \${TMPDIR:-/tmp}/lab-07-<namespace>)
  GIT_REPO_URL=URL       HTTPS URL of the trainer's repository (force-pushed!)
  GIT_USERNAME, GIT_TOKEN  credentials for push and for Argo CD"
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
    on_exit_cleanup cleanup "Delete the lab resources (${LAB_NS} and ${LAB_NS}-shop for the default namespace)? [y/N]"

    title "Lab 07 – Metrics, alerts and logs" \
          "ServiceMonitor · up · PromQL · PrometheusRule · logs"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "A ServiceMonitor selects Services by label and the port by name" \
      "Run 'up' first – a missing target or a 0 explains an empty graph" \
      "rate() for counters, histogram_quantile() for latency" \
      "An alert is a query with a threshold and for: – kept in Git" \
      "The request id leads from the alert to the log lines in every service"

    if ask "Run the bonus tasks too? [y/N]"; then
      bonus
    fi
    stop_traffic
    check || true
    ;;
esac
