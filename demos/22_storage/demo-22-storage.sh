#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo 22 – Storage: PVC, StorageClass, PV
#  Run:     ./demo-22-storage.sh [-n|--namespace NAME] [STEP|cleanup]
#  Expects: oc logged in – cluster-admin for step 0 (reads the PV) and step 3
#           (lists the nodes); the default StorageClass is block storage (RWO),
#           e.g. gp3-csi on AWS; a VolumeSnapshotClass (step 4, see snapshot.yaml)
#  The demo runs in the project "demo-storage" (or NAME), created if missing.
#
#    0  Pending → Bound      WaitForFirstConsumer, the PV and its zone
#    1  RWX on block storage the PVC never binds
#    2  data outlives Pods   write, delete the Pod, read again
#    3  the RWO trap         rolling update onto another node → Multi-Attach
#    4  snapshot + restore   a new PVC from a VolumeSnapshot
# ---------------------------------------------------------------------------
set -euo pipefail

DEMO_PROJECT="${DEMO_PROJECT:-demo-storage}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/demo-lib.sh
source "${SCRIPT_DIR}/../lib/demo-lib.sh"

DEMO_USAGE_ARGS="[STEP|cleanup]"
DEMO_USAGE_EXTRA="  STEP                   run only this step (0-4); default: all steps
  cleanup                delete the demo objects (PVCs and snapshot included)"
parse_demo_args "$@"

MODE="${DEMO_ARGS[0]:-all}"
case "${MODE}" in
  all|[0-4]|cleanup) ;;
  *) demo_usage >&2; die "Unknown step: ${MODE}" ;;
esac

cd "${SCRIPT_DIR}" || die "Cannot cd to ${SCRIPT_DIR}"

# ═══════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════

pvc_phase() { oc get pvc "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true; }

writer_ready() {   # the PVC "data" with a Pod "writer" on it (for single steps)
  oc apply -f pvc.yaml -f writer.yaml >/dev/null
  oc wait --for=condition=Ready pod/writer --timeout=180s >/dev/null 2>&1 || true
}

# other_node NODE – a schedulable node in the same zone as NODE (the disk can follow
# only within its zone), or nothing
other_node() {
  local zone
  zone="$(oc get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
  oc get nodes -l "topology.kubernetes.io/zone=${zone}" \
    -o jsonpath='{range .items[?(@.spec.unschedulable!=true)]}{.metadata.name}{"\n"}{end}' \
    | grep -vx "$1" | head -1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Cleanup
# ═══════════════════════════════════════════════════════════════════════════

cleanup() {
  info "deleting the demo objects in ${DEMO_PROJECT} ..."
  oc delete pod writer reader shared-user --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete deployment app --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete volumesnapshot data-snap --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete pvc data data-restored shared app-data --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════════════════
#  Steps
# ═══════════════════════════════════════════════════════════════════════════

step0() {
  section "0 · Pending → Bound – the disk is created when a Pod needs it"

  run "oc get storageclass"
  show_file pvc.yaml
  run "oc apply -f pvc.yaml"
  run "oc get pvc data"
  run "oc describe pvc data | tail -4"
  comment "Pending is normal – now a Pod that uses the PVC"
  show_file writer.yaml
  run "oc apply -f writer.yaml"
  run "oc wait --for=condition=Ready pod/writer --timeout=180s"
  run "oc get pvc data"
  comment "The PV was created for us – and it is tied to one zone"
  run "PV=\$(oc get pvc data -o jsonpath='{.spec.volumeName}'); echo \$PV"
  run "oc get pv \$PV -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0]}{\"\\n\"}'"
  run "oc get pod writer -o jsonpath='{.spec.nodeName}{\"\\n\"}'"

  discuss \
    "PVC → StorageClass → PV" \
    "" \
    "The PVC waited (WaitForFirstConsumer) until writer was scheduled." \
    "Then the CSI driver created a disk in THAT node's zone and a PV." \
    "The PV is pinned to the zone: Pods using it must run there."
}

step1() {
  section "1 · ReadWriteMany on block storage – it never binds"

  show_file pvc-rwx.yaml
  run "oc apply -f pvc-rwx.yaml"
  info "   waiting 20 s for the provisioner ..."
  sleep 20
  run "oc get pvc shared"
  run "oc get events --field-selector involvedObject.name=shared | tail -3"
  run "oc get pod shared-user"
  run "oc delete -f pvc-rwx.yaml --wait=false"

  discuss \
    "The access mode is a request - the storage must support it" \
    "" \
    "EBS is a block device: one node at a time. RWX needs file storage" \
    "(EFS, CephFS, NFS) - ask the platform team which class has it." \
    "Pending forever, and the Pod waits with it."
}

step2() {
  section "2 · The data outlives the Pod"
  [[ "${MODE}" == "2" ]] && writer_ready

  run "oc exec writer -- sh -c 'date > /data/hello.txt; ls -l /data; cat /data/hello.txt'"
  run "oc delete pod writer"
  run "oc apply -f writer.yaml"
  run "oc wait --for=condition=Ready pod/writer --timeout=180s"
  run "oc exec writer -- cat /data/hello.txt"
  comment "Who may write? The random UID – and the fsGroup the volume got"
  run "oc exec writer -- id"
  run "oc exec writer -- ls -ld /data"

  discuss \
    "Pods come and go - the PVC keeps the data" \
    "" \
    "Same file, new Pod. The PVC lives until YOU delete it." \
    "restricted-v2 sets an fsGroup: the volume is group-writable" \
    "for the random UID - no chown in the image needed."
}

step3() {
  section "3 · The RWO trap – a rolling update onto another node"

  show_file deployment.yaml
  run "oc apply -f deployment.yaml"
  run "oc rollout status deployment/app --timeout=180s"
  local node other
  node="$(oc get pod -l app.kubernetes.io/name=app -o jsonpath='{.items[0].spec.nodeName}')"
  other="$(other_node "${node}")"
  if [[ -z "${other}" ]]; then
    warn "No second schedulable node in the zone of ${node} – step 3 needs one. Skipped."
    return 0
  fi
  export OTHER="${other}"
  comment "The Pod runs on ${node}. A new version that must run on ${other} – same zone:"
  run "oc patch deployment app --type=merge -p '{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"'\$OTHER'\"}}}}}'"
  info "   waiting 40 s – RollingUpdate starts the new Pod while the old one still holds the disk ..."
  sleep 40
  run "oc get pods -l app.kubernetes.io/name=app -o wide"
  run "oc get events --field-selector reason=FailedAttachVolume | tail -2"
  pause

  comment "The fix: Recreate – the old Pod goes first, then the disk can move"
  run "oc patch deployment app --type=merge -p '{\"spec\":{\"strategy\":{\"type\":\"Recreate\",\"rollingUpdate\":null}}}'"
  run "oc rollout status deployment/app --timeout=300s"
  run "oc get pods -l app.kubernetes.io/name=app -o wide"

  discuss \
    "RWO = one NODE - and a rolling update needs two Pods" \
    "" \
    "Multi-Attach: the disk is still attached to the old node." \
    "Recreate: a short downtime, but no deadlock - recommended for EBS." \
    "Databases: a StatefulSet. More replicas: RWX or one PVC each."
}

step4() {
  section "4 · Snapshot and restore"
  [[ "${MODE}" == "4" ]] && writer_ready && oc exec writer -- sh -c 'date > /data/hello.txt' >/dev/null

  run "oc get volumesnapshotclass"
  show_file snapshot.yaml
  run "oc apply -f snapshot.yaml"
  run "oc wait volumesnapshot/data-snap --for=jsonpath='{.status.readyToUse}'=true --timeout=300s"
  run "oc get volumesnapshot data-snap"
  comment "Oops – the file is gone"
  run "oc exec writer -- rm /data/hello.txt"
  run "oc exec writer -- ls -l /data"
  comment "A NEW PVC from the snapshot – the original stays as it is"
  show_file restore.yaml
  run "oc apply -f restore.yaml"
  run "oc wait --for=condition=Ready pod/reader --timeout=300s"
  run "oc exec reader -- cat /data/hello.txt"
  run "oc get pvc"

  discuss \
    "Snapshot → new PVC (dataSource)" \
    "" \
    "A restore never overwrites - it creates a second volume." \
    "Before a risky upgrade: snapshot first. But a snapshot lives on" \
    "the same storage system - it is not a backup (OADP: platform team)."
}

# ═══════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════
require_oc_login

case "${MODE}" in
  cleanup)
    cleanup
    success "Cleaned up."
    ;;
  [0-4])
    # single step: no cleanup question – the next step builds on this one
    "step${MODE}"
    ;;
  all)
    cleanup
    oc wait --for=delete pvc -l app.kubernetes.io/part-of=demo-22 --timeout=120s >/dev/null 2>&1 || true
    on_exit_cleanup cleanup "Delete the demo objects – PVCs, disks and snapshot? [y/N]"

    title "Demo 22 – Storage" "PVC · StorageClass · PV · access modes · snapshots"
    for i in 0 1 2 3 4; do "step${i}"; done

    takeaways \
      "You write the PVC - the StorageClass creates disk and PV" \
      "Pending until a Pod needs it - then the disk sits in one zone" \
      "The access mode must be supported - RWX needs file storage" \
      "RWO + RollingUpdate on another node = Multi-Attach - use Recreate" \
      "Restore = a new PVC from a snapshot - and a snapshot is no backup"
    ;;
esac
