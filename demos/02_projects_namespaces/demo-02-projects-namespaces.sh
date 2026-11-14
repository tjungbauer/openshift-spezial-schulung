#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 02 – Projects & Namespaces
#  Run:     ./demo-02-projects-namespaces.sh
#  Expects: oc logged in (project "demo" is created if missing)
#  Note:    section 3 creates a temporary project, but only if the user
#           is allowed to (self-provisioner). It is deleted on exit.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"
cd "${SCRIPT_DIR}"

TMP_PROJECT=""

cleanup() {
  if [[ -n "${TMP_PROJECT}" ]]; then
    oc delete project "${TMP_PROJECT}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login
on_exit_cleanup cleanup "Delete the temporary project (if created)? [y/N]"

# ═══════════════════════════════════════════════════════════════════════════
#  DEMO
# ═══════════════════════════════════════════════════════════════════════════
title "Demo 02 – Projects & Namespaces" "oc status · project vs. namespace"

# ── 1 · Current project ────────────────────────────────────────────────────
section "1 · Which project am I using?"

comment "oc status gives an overview of the current project"
run "oc status"

comment "Store the current project name in a variable"
run "export PROJECT=\$(oc project -q)"
run "echo \${PROJECT}"

# ── 2 · Project vs. namespace ──────────────────────────────────────────────
section "2 · Project vs. namespace"

comment "Are there any annotations on the project?"
run "oc describe project \${PROJECT}"

comment "Now the same object, seen as a Kubernetes namespace"
run "oc describe namespace \${PROJECT}"

discuss \
  "Project = Namespace + OpenShift extras" \
  "" \
  "Every project IS a namespace (same name, same object)." \
  "OpenShift adds annotations, e.g.:" \
  "  - openshift.io/display-name, openshift.io/description" \
  "  - openshift.io/requester (who created it)" \
  "  - openshift.io/sa.scc.uid-range (UIDs for pods -> SCC)" \
  "" \
  "Projects are created via a ProjectRequest (template)," \
  "so admins can add limits, network policies, RBAC."

# ── 3 · Projects are a filtered view ───────────────────────────────────────
section "3 · Projects: what I am allowed to see"

comment "Projects list only the namespaces you have access to"
run "oc get projects"

discuss \
  "Projects for multi-tenancy" \
  "" \
  "  - oc get projects: only the namespaces I may access" \
  "  - oc get namespaces: requires cluster-wide list rights" \
  "  - oc new-project: self-service (if self-provisioner is granted)" \
  "  - oc project <name>: switch the current context"

takeaways \
  "Every OpenShift project is a Kubernetes namespace" \
  "Projects add annotations: display name, requester, UID range" \
  "Projects show only what you are allowed to see" \
  "Use 'oc project -q' in scripts to get the current project"
