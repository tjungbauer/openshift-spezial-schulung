# shellcheck shell=bash
# ---------------------------------------------------------------------------
#  Shared helpers for the interactive OpenShift demo scripts.
#
#  Usage (at the top of a demo script):
#
#     SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#     source "${SCRIPT_DIR}/../lib/demo-lib.sh"
#
#  Environment variables:
#     DEMO_THEME_FILE  alternative colour theme (default: lib/theme.sh)
#     DEMO_AUTO=1      do not wait for ENTER (dry runs / testing)
#     DEMO_CLEANUP=y|n answer the cleanup question up front
#     DEMO_LABEL       label used on all demo objects (openshift-example=yes)
#     DEMO_PROJECT     project/namespace the demos run in (default: demo)
#     NO_COLOR=1       disable colours
#
#  Written for bash 3.2 (macOS default) and newer.
# ---------------------------------------------------------------------------

[[ -n "${_DEMO_LIB_LOADED:-}" ]] && return 0
_DEMO_LIB_LOADED=1

DEMO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=theme.sh
source "${DEMO_THEME_FILE:-${DEMO_LIB_DIR}/theme.sh}"

DEMO_AUTO="${DEMO_AUTO:-0}"
DEMO_LABEL="${DEMO_LABEL:-openshift-example=yes}"
DEMO_PROJECT="${DEMO_PROJECT:-demo}"
DEMO_WIDTH=72

_demo_step=0
_demo_cleanup_fn=""
_demo_cleanup_question=""
_demo_always_fn=""
_demo_orig_project=""

# ═══════════════════════════════════════════════════════════════════════════
#  Internal helpers
# ═══════════════════════════════════════════════════════════════════════════

# _repeat CHAR COUNT – print CHAR COUNT times (no newline)
_repeat() {
  local i out=""
  for ((i = 0; i < $2; i++)); do out="${out}$1"; done
  printf "%s" "${out}"
}

# _wait_enter MESSAGE – wait for ENTER; 'q' aborts the demo
_wait_enter() {
  local input=""
  [[ "${DEMO_AUTO}" == "1" ]] && return 0
  printf "%s   %s%s" "${C_DIM}" "$1" "${C_RESET}"
  read -r input || true
  if [[ "${input}" == "q" ]]; then
    printf "Demo aborted.\n"
    exit 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Output helpers
# ═══════════════════════════════════════════════════════════════════════════

# title "Demo 01 – Simple Pods" "subtitle"
title() {
  local inner=$((DEMO_WIDTH - 8)) line
  printf "\n%s" "${C_BOLD}"
  printf "  ╔%s╗\n" "$(_repeat '═' "${inner}")"
  for line in "$@"; do
    printf "  ║   %s%s║\n" "${line}" "$(_repeat ' ' $((inner - 3 - ${#line})))"
  done
  printf "  ╚%s╝\n" "$(_repeat '═' "${inner}")"
  printf "%s\n" "${C_RESET}"
  printf "%sPress ENTER to advance through each command.%s\n" "${C_DIM}" "${C_RESET}"
  printf "%sType 'q' + ENTER at any prompt to quit.%s\n" "${C_DIM}" "${C_RESET}"
}

# section "1 · Something"
section() {
  printf "\n"
  printf "%s%s%s\n" "${C_BOLD}" "$(_repeat '━' "${DEMO_WIDTH}")" "${C_RESET}"
  printf "%s  %s%s\n" "${C_HEADING}" "$1" "${C_RESET}"
  printf "%s%s%s\n" "${C_BOLD}" "$(_repeat '━' "${DEMO_WIDTH}")" "${C_RESET}"
}

# comment "explanation shown before a command"
comment() {
  printf "\n%s# %s%s\n" "${C_COMMENT}" "$*" "${C_RESET}"
}

info()    { printf "%s%s%s\n" "${C_DIM}" "$*" "${C_RESET}"; }
success() { printf "%s✔ %s%s\n" "${C_OK}" "$*" "${C_RESET}"; }
warn()    { printf "%s⚠ %s%s\n" "${C_WARN}" "$*" "${C_RESET}"; }
die()     { printf "%sERROR: %s%s\n" "${C_ERR}" "$*" "${C_RESET}" >&2; exit 1; }

# run "command" – show the command, wait for ENTER, execute it.
# A failing command does not abort the demo (failures are often the lesson).
run() {
  local rc=0
  _demo_step=$((_demo_step + 1))
  printf "\n%s── step %s %s%s\n" "${C_DIM}" "${_demo_step}" "$(_repeat '─' 50)" "${C_RESET}"
  printf "%s▶ %s%s%s\n" "${C_PROMPT}" "${C_CMD}" "$*" "${C_RESET}"
  _wait_enter "Press ENTER to run (or 'q' to quit)..."
  printf "\n"
  eval "$*" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf "%s   (exit code %s)%s\n" "${C_WARN}" "${rc}" "${C_RESET}"
  fi
  return 0
}

# pause – wait for ENTER
pause() {
  printf "\n"
  _wait_enter "Press ENTER to continue..."
}

# show_file PATH – print a file with a header
show_file() {
  printf "\n%s── file: %s %s%s\n" "${C_DIM}" "$1" "$(_repeat '─' 40)" "${C_RESET}"
  printf "%s" "${C_FILE}"
  cat "$1"
  printf "%s\n" "${C_RESET}"
}

# discuss "Title" "line" "line" ... – highlighted box to talk about, then pause
discuss() {
  local inner=${DEMO_WIDTH} maxlen=$((DEMO_WIDTH - 4)) line colour first=1
  printf "\n"
  printf "%s%s╔%s╗%s\n" "${C_DISCUSS_BG}" "${C_DISCUSS_TITLE}" "$(_repeat '═' "${inner}")" "${C_RESET}"
  printf "%s%s║%s║%s\n" "${C_DISCUSS_BG}" "${C_DISCUSS_TITLE}" "$(_repeat ' ' "${inner}")" "${C_RESET}"
  for line in "$@"; do
    [[ ${#line} -gt ${maxlen} ]] && line="${line:0:${maxlen}}"
    if [[ ${first} -eq 1 ]]; then colour="${C_DISCUSS_TITLE}"; first=0; else colour="${C_DISCUSS_BODY}"; fi
    printf "%s%s║  %s%s%s║%s\n" "${C_DISCUSS_BG}" "${colour}" "${line}" \
      "$(_repeat ' ' $((inner - 2 - ${#line})))" "${C_DISCUSS_TITLE}" "${C_RESET}"
  done
  printf "%s%s║%s║%s\n" "${C_DISCUSS_BG}" "${C_DISCUSS_TITLE}" "$(_repeat ' ' "${inner}")" "${C_RESET}"
  printf "%s%s╚%s╝%s\n" "${C_DISCUSS_BG}" "${C_DISCUSS_TITLE}" "$(_repeat '═' "${inner}")" "${C_RESET}"
  pause
}

# takeaways "point" "point" ... – closing summary
takeaways() {
  local point
  section "Demo complete!"
  printf "\n%sKey takeaways:%s\n" "${C_OK}" "${C_RESET}"
  for point in "$@"; do printf "  • %s\n" "${point}"; done
  printf "\n"
}

# ask "Question? [y/N]" – returns 0 on yes
ask() {
  local answer=""
  printf "%s%s %s" "${C_DIM}" "$1" "${C_RESET}"
  if [[ "${DEMO_AUTO}" == "1" ]]; then printf "n\n"; return 1; fi
  read -r answer || true
  [[ "${answer}" =~ ^[Yy]$ ]]
}

# ask_alert "Question? [y/N]" – like ask, but impossible to overlook
# (red banner; used for the cleanup question on exit)
ask_alert() {
  local answer="" text=" ⚠  $1 "
  printf "\n%s%s%s\n" "${C_ALERT_LINE}" "$(_repeat '━' "${DEMO_WIDTH}")" "${C_RESET}"
  printf "%s%s%s%s " "${C_ALERT}" "${text}" "$(_repeat ' ' $((DEMO_WIDTH - ${#text})))" "${C_RESET}"
  if [[ "${DEMO_AUTO}" == "1" ]]; then printf "n\n"; return 1; fi
  read -r answer || true
  [[ "${answer}" =~ ^[Yy]$ ]]
}

# ═══════════════════════════════════════════════════════════════════════════
#  Waiting
# ═══════════════════════════════════════════════════════════════════════════

# wait_until "description" TIMEOUT_SECONDS "command" – poll until command succeeds
wait_until() {
  local desc="$1" timeout="$2" cmd="$3" waited=0
  printf "%s   waiting: %s " "${C_DIM}" "${desc}"
  while ! eval "${cmd}" >/dev/null 2>&1; do
    if [[ ${waited} -ge ${timeout} ]]; then
      printf "%s\n" "${C_RESET}"
      warn "gave up after ${timeout}s – continuing anyway"
      return 1
    fi
    printf "."
    sleep 2
    waited=$((waited + 2))
  done
  printf " done (%ss)%s\n" "${waited}" "${C_RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  OpenShift helpers
# ═══════════════════════════════════════════════════════════════════════════

# parse_demo_args "$@" – common command line options for demo scripts:
#   -n, --namespace NAME   project/namespace to use (default: $DEMO_PROJECT or "demo")
#   -h, --help             show usage
# The command line wins over the DEMO_PROJECT environment variable.
#
# Scripts that take positional arguments set, BEFORE calling parse_demo_args:
#   DEMO_USAGE_ARGS="[STEP|cleanup]"     shown in the usage line
#   DEMO_USAGE_EXTRA="text"              extra help text
# Positional arguments end up in the array DEMO_ARGS. Scripts without
# DEMO_USAGE_ARGS reject positional arguments.
DEMO_ARGS=()
parse_demo_args() {
  DEMO_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ -n "${2:-}" ]] || die "Option $1 needs a namespace name."
        DEMO_PROJECT="$2"
        shift 2
        ;;
      --namespace=*)
        DEMO_PROJECT="${1#*=}"
        shift
        ;;
      -h|--help)
        demo_usage
        exit 0
        ;;
      -*)
        demo_usage >&2
        die "Unknown option: $1"
        ;;
      *)
        DEMO_ARGS+=("$1")
        shift
        ;;
    esac
  done
  if [[ ${#DEMO_ARGS[@]} -gt 0 && -z "${DEMO_USAGE_ARGS:-}" ]]; then
    demo_usage >&2
    die "Unexpected argument: ${DEMO_ARGS[0]}"
  fi
  [[ "${DEMO_PROJECT}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#DEMO_PROJECT} -le 63 ]] \
    || die "'${DEMO_PROJECT}' is not a valid namespace name (lowercase letters, digits and '-', max. 63 characters)."
}

demo_usage() {
  cat <<EOF
Usage: $(basename "$0") [-n|--namespace NAME] ${DEMO_USAGE_ARGS:+${DEMO_USAGE_ARGS} }[-h|--help]

  -n, --namespace NAME   project/namespace to run the demo in
                         (default: ${DEMO_PROJECT}; created if it does not exist)
  -h, --help             show this help
EOF
  [[ -n "${DEMO_USAGE_EXTRA:-}" ]] && printf "\n%s\n" "${DEMO_USAGE_EXTRA}"
  printf "\nEnvironment: DEMO_PROJECT, DEMO_CLEANUP=y|n, DEMO_AUTO=1, NO_COLOR=1\n"
}

# yq_to_json_cmd FILE – print the yq command that converts FILE to compact
# JSON, for whichever yq is installed (mikefarah/yq or python-yq). Prints
# nothing if there is no usable yq.
yq_to_json_cmd() {
  local version
  version="$(yq --version 2>&1 || true)"
  case "${version}" in
    *mikefarah*|"yq version"*) printf 'yq -o json -I0 %s' "$1" ;;  # mikefarah/yq
    *jq-*)                     printf 'yq -c . %s' "$1" ;;         # python-yq (jq wrapper)
  esac
}

# yaml_to_json FILE – print FILE as compact JSON (yq, python3+PyYAML or ruby)
yaml_to_json() {
  local cmd
  cmd="$(yq_to_json_cmd "$1")"
  if [[ -n "${cmd}" ]]; then
    eval "${cmd}"
  elif python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys, json, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])), separators=(",", ":")))' "$1"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))' "$1"
  else
    die "Cannot convert $1 to JSON – please install yq."
  fi
}

# require_cmd NAME... – abort if a command is missing
require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "'${c}' not found in PATH."
  done
}

# require_oc_login – check login, switch to DEMO_PROJECT (create it if
# needed), set OC_USER / OC_SERVER / OC_PROJECT and print them.
require_oc_login() {
  require_cmd oc
  oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift. Run 'oc login' first."
  OC_USER="$(oc whoami)"
  OC_SERVER="$(oc whoami --show-server)"
  printf "\n%sCluster:%s %s\n" "${C_BOLD}" "${C_RESET}" "${OC_SERVER}"
  printf "%sUser:   %s %s\n" "${C_BOLD}" "${C_RESET}" "${OC_USER}"
  use_demo_project
  OC_PROJECT="${DEMO_PROJECT}"
  printf "%sProject:%s %s\n" "${C_BOLD}" "${C_RESET}" "${OC_PROJECT}"
}

# use_demo_project – make sure DEMO_PROJECT exists and is the current project.
# The previous project is restored when the script exits.
use_demo_project() {
  _demo_orig_project="$(oc project -q 2>/dev/null || true)"
  trap _demo_on_exit EXIT
  trap 'exit 130' INT TERM

  if oc get project "${DEMO_PROJECT}" >/dev/null 2>&1; then
    oc project "${DEMO_PROJECT}" >/dev/null || die "Cannot switch to project '${DEMO_PROJECT}'."
    info "Using existing project '${DEMO_PROJECT}'."
  elif oc new-project "${DEMO_PROJECT}" --display-name="Demo" \
         --description="Project for the OpenShift training demos" >/dev/null 2>&1 \
       || { oc create namespace "${DEMO_PROJECT}" >/dev/null 2>&1 \
            && oc project "${DEMO_PROJECT}" >/dev/null 2>&1; }; then
    success "Created project '${DEMO_PROJECT}'."
  else
    die "Could not create project '${DEMO_PROJECT}' (missing permissions, or it is still terminating?)."
  fi
}

# delete_quietly KIND NAME... – delete objects in DEMO_PROJECT, ignore missing ones
delete_quietly() {
  oc delete "$@" -n "${DEMO_PROJECT}" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup on exit
# ═══════════════════════════════════════════════════════════════════════════

# on_exit_always FUNCTION – always run FUNCTION on exit, before the cleanup
# question (stop background processes, switch back to the original project…)
on_exit_always() {
  _demo_always_fn="$1"
  trap _demo_on_exit EXIT
  trap 'exit 130' INT TERM
}

# on_exit_cleanup FUNCTION "Question?" – ask on exit (also on 'q' / Ctrl-C)
# whether FUNCTION should be run. DEMO_CLEANUP=y|n skips the question.
on_exit_cleanup() {
  _demo_cleanup_fn="$1"
  _demo_cleanup_question="${2:-Clean up demo resources? [y/N]}"
  trap _demo_on_exit EXIT
  trap 'exit 130' INT TERM
}

_demo_on_exit() {
  local do_it=1
  [[ -n "${_demo_always_fn}" ]] && "${_demo_always_fn}"
  if [[ -n "${_demo_cleanup_fn}" ]]; then
    printf "\n"
    case "${DEMO_CLEANUP:-}" in
      y|Y) do_it=0 ;;
      n|N) do_it=1 ;;
      *)   ask_alert "${_demo_cleanup_question}" && do_it=0 ;;
    esac
    if [[ ${do_it} -eq 0 ]]; then
      "${_demo_cleanup_fn}"
      success "Cleaned up."
    fi
  fi
  if [[ -n "${_demo_orig_project}" && "${_demo_orig_project}" != "${DEMO_PROJECT}" ]]; then
    oc project "${_demo_orig_project}" >/dev/null 2>&1 \
      && info "Switched back to project '${_demo_orig_project}'."
  fi
  return 0
}
