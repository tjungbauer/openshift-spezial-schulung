#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 04 – Overlays and a component: interactive walkthrough
#  Run:     ./lab-04-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, curl
#
#  Builds base, overlays and a component step by step, like the students
#  (ENTER runs each command). Default namespace: lab (created).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-04-lib.sh
source "${SCRIPT_DIR}/lab-04-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus tasks
  cleanup                delete what the lab created

  LAB_NS=NAME            same as -n NAME
  WORK_DIR=PATH          where the files are built (default: \${TMPDIR:-/tmp}/lab-04-<namespace>)"
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
    on_exit_cleanup cleanup "Delete the lab resources (dev and prod in ${LAB_NS})? [y/N]"

    title "Lab 04 – Overlays and a component" \
          "base · overlays · component · generator · diff · apply"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "Base = what all share, overlays = the differences, components = features" \
      "namePrefix renames only the references Kustomize knows" \
      "Selectors decide which Pods a Service gets – set them before the first apply" \
      "A generator hash turns a config change into a rolling update" \
      "oc diff -k before every apply – and oc apply -k never deletes"

    if ask "Run the bonus tasks too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
