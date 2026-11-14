#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Lab 05 – Deploy the website with Argo CD: interactive walkthrough
#  Run:     ./lab-05-walkthrough.sh [-n|--namespace NAME] [TASK|bonus|cleanup]
#  Expects: oc logged in, curl, git; GIT_REPO_URL, GIT_USERNAME, GIT_TOKEN
#
#  Runs the commands of the student README (ENTER runs each command):
#  Git repository, Argo CD Applications, self heal, hook and wave, promotion
#  by digest, git revert. Default namespace: lab (created, with its own
#  Argo CD instance). GIT_REPO_URL must point to a repository the trainer
#  owns – the scripts force-push to its branch main.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-05-lib.sh
source "${SCRIPT_DIR}/lab-05-lib.sh"

DEMO_USAGE_ARGS="[TASK|bonus|cleanup]"
DEMO_USAGE_EXTRA="  TASK                   run only this task (1-6); default: all tasks
  bonus                  run only the bonus task (prune)
  cleanup                delete what the lab created

  LAB_NS=NAME            same as -n NAME
  WORK_DIR=PATH          where the repository is built (default: \${TMPDIR:-/tmp}/lab-05-<namespace>)
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
    on_exit_cleanup cleanup "Delete the lab resources (Applications, dev and prod in ${LAB_NS})? [y/N]"

    title "Lab 05 – Deploy the website with Argo CD" \
          "Git · Application · self heal · hook & wave · digest · git revert"
    for i in 1 2 3 4 5 6; do "task${i}"; done

    takeaways \
      "Git holds the desired state – the Application says where it goes" \
      "Self heal undoes manual changes – change Git, not the cluster" \
      "Hooks and waves order a sync – by annotation, not by script" \
      "Promote by digest – prod runs exactly what dev tested" \
      "Roll back with git revert – reviewed, and auto-sync stays on"

    if ask "Run the bonus tasks too? [y/N]"; then
      bonus
    fi
    check || true
    ;;
esac
