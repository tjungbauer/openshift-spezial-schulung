# Demo 22 – Storage: PVC, StorageClass, PV

A PVC from `Pending` to `Bound`, an access mode the storage cannot provide, data that outlives
its Pod, the RWO trap of a rolling update – and a snapshot that brings a deleted file back.
Runs in its own project `demo-storage`.

```bash
cd demos/22_storage
./demo-22-storage.sh              # all steps (about 12 minutes)
./demo-22-storage.sh 3            # one step (creates what it needs)
./demo-22-storage.sh cleanup      # PVCs, disks and snapshot included
```

Needs `oc` (logged in) and:

- **cluster-admin** for two commands: step 0 reads the PV (cluster-scoped), step 3 lists the
  nodes to pick a second one;
- a **default StorageClass with block storage** (RWO only) – on the training cluster `gp3-csi`
  (AWS EBS). With file storage as default (RWX possible), step 1 binds instead of failing;
- a **VolumeSnapshotClass** for step 4 – on the training cluster `csi-aws-vsc`. Another cluster:
  `oc get volumesnapshotclass`, then change `snapshot.yaml`;
- for step 3: a second schedulable node **in the same zone** as the first Pod – an EBS disk can
  only move within its zone. Without one, step 3 is skipped with a warning.

The cluster pulls `registry.access.redhat.com/ubi9/ubi:9.9`.

| Step | What you see |
|---|---|
| 0 | `data` stays `Pending` (event: waiting for first consumer) – the Pod `writer` starts, the PVC turns `Bound`; the PV is pinned to the zone of the node |
| 1 | `shared` asks for `ReadWriteMany` – `Pending` with `Volume capabilities not supported`; its Pod waits too |
| 2 | a file written by `writer` survives `oc delete pod writer`; `id` and `ls -ld /data` show the random UID and the fsGroup |
| 3 | Deployment `app` with an RWO PVC; a new version pinned to another node in the same zone: the new Pod hangs in `ContainerCreating`, event `FailedAttachVolume` – Multi-Attach. `strategy: Recreate` – the rollout finishes |
| 4 | `VolumeSnapshot` of `data`, the file is deleted, a new PVC `data-restored` from the snapshot – the file is back |

The files:

| File | Content |
|---|---|
| `pvc.yaml` | PVC `data` – RWO, 1 GiB, default StorageClass |
| `writer.yaml` | Pod `writer` (UBI 9) that mounts `data` at `/data` |
| `pvc-rwx.yaml` | PVC `shared` with `ReadWriteMany` and the Pod `shared-user` that triggers provisioning |
| `deployment.yaml` | PVC `app-data` and Deployment `app` (RollingUpdate – the default) |
| `snapshot.yaml` | VolumeSnapshot `data-snap` of `data`, class `csi-aws-vsc` |
| `restore.yaml` | PVC `data-restored` with `dataSource` = the snapshot, and the Pod `reader` |

Step 3 by hand – the interesting part:

```bash
oc apply -f deployment.yaml
oc rollout status deployment/app
oc get pod -l app.kubernetes.io/name=app -o wide          # the node – and its zone:
oc get nodes -L topology.kubernetes.io/zone                # pick another node in that zone
OTHER=<that node>
oc patch deployment app --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"'$OTHER'"}}}}}'
oc get events --field-selector reason=FailedAttachVolume  # Multi-Attach error
oc patch deployment app --type=merge \
  -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
oc rollout status deployment/app
```

`rollingUpdate: null` is needed: the API rejects `rollingUpdate` settings together with
`type: Recreate`.

Cleanup deletes the PVCs – with the reclaim policy `Delete` the EBS disks go with them – and
the snapshot.
