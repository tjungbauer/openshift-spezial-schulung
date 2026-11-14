#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 03 – Your own Helm chart: interactive walkthrough
#  Run:     ./lab-03-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, helm, curl
#
#  Builds the chart "website" step by step, the same way as the students
#  (ENTER runs each command). Default namespace: lab (created).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-03-lib.sh
source "${SCRIPT_DIR}/lab-03-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus task
  cleanup                uninstall the release, delete what the lab created

  LAB_NS=NAME            same as -n NAME
  WORK_DIR=PATH          where the chart is built (default: \${TMPDIR:-/tmp}/lab-03-<namespace>)"
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
    on_exit_cleanup cleanup "Delete the lab resources (release ${RELEASE} in ${LAB_NS})? [y/N]"

    title "Lab 03 – Your own Helm chart" \
          "helm create · values · templates · install · upgrade · rollback"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "helm create gives a starting point – keep the helpers, write the rest" \
      "Chart.yaml: version = chart, appVersion = application" \
      "values.yaml: only the knobs you want to offer" \
      "helm template and helm lint before every install" \
      "Every upgrade and rollback is a new revision"

    if ask "Run the bonus task too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
