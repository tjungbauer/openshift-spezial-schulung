# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by demo-lib.sh
# ---------------------------------------------------------------------------
#  Colour theme for all demo scripts.
#
#  This is the ONLY place where colours are defined. To use a different
#  theme, copy this file and point DEMO_THEME_FILE at it:
#
#     DEMO_THEME_FILE=~/my-theme.sh ./demo-01-simple-pod.sh
#
#  Colours are disabled automatically when NO_COLOR is set
#  (https://no-color.org) or when stdout is not a terminal.
# ---------------------------------------------------------------------------

if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  C_BOLD="" C_DIM="" C_RESET=""
  C_CMD="" C_PROMPT="" C_HEADING="" C_COMMENT=""
  C_OK="" C_WARN="" C_ERR="" C_FILE=""
  C_DISCUSS_BG="" C_DISCUSS_TITLE="" C_DISCUSS_BODY=""
  C_ALERT="" C_ALERT_LINE=""
  return 0
fi

# ── basics ─────────────────────────────────────────────────────────────────
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'

# ── semantic colours (use these in scripts, not raw escape codes) ─────────
C_CMD=$'\033[1;36m'        # the command that is about to run   (cyan)
C_PROMPT=$'\033[1;32m'     # the ▶ marker in front of a command  (green)
C_HEADING=$'\033[1;33m'    # section banners                     (yellow)
C_COMMENT=$'\033[1;33m'    # "# explanation" lines                (yellow)
C_FILE=$'\033[1;36m'       # contents printed by show_file        (cyan)
C_OK=$'\033[1;32m'         # success messages                    (green)
C_WARN=$'\033[1;33m'       # warnings                            (yellow)
C_ERR=$'\033[1;31m'        # errors                              (red)

# ── discussion box ─────────────────────────────────────────────────────────
C_DISCUSS_BG=$'\033[48;5;88m'     # dark red background
C_DISCUSS_TITLE=$'\033[1;97m'     # bright white, bold
C_DISCUSS_BODY=$'\033[38;5;224m'  # light pink

# ── important questions (cleanup on exit) ─────────────────────────────────
C_ALERT=$'\033[1;97;41m'          # bold white on red
C_ALERT_LINE=$'\033[1;31m'        # red rule above the question
