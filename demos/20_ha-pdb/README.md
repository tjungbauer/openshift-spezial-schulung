# Demo 20 – Spread and PDB at work

catalog and a `probe` Pod that calls it five times per second – "the users". One replica turns
every Pod restart into an outage; three spread replicas, a PodDisruptionBudget and a careful
rolling update make the same events invisible. Runs in its own project `demo-ha`. About 7 minutes.

```bash
cd demos/20_ha-pdb
./demo-20-ha-pdb.sh              # all steps
./demo-20-ha-pdb.sh 2            # one step (creates what it needs)
./demo-20-ha-pdb.sh cleanup
```

| Step | What you see |
|---|---|
| 0 | one replica, `oc delete pod` – the probe gets `000` / `503` until the new Pod is ready |
| 1 | `spread.yaml`: 3 replicas, `topologySpreadConstraints` on hostname (`DoNotSchedule`) and zone (`ScheduleAnyway`) – `oc get pods -o wide` shows three nodes |
| 2 | `pdb.yaml` (`minAvailable: 2`), two Evictions by hand: the first is accepted, the second gets **429** – "would violate the pod's disruption budget" |
| 3 | `oc rollout restart` under load – `maxUnavailable: 0`, readiness, `preStop` sleep 5 s: only `200` |

Needs `oc` (logged in) and namespace rights only: Evictions go through the Pod's `eviction`
subresource, the same call `oc adm drain` makes – no node rights needed. If you may list nodes,
step 1 also shows the zone of every worker. Best on a cluster with 3 workers in 3 zones; with 2
workers the hostname spread places 2 + 1. The cluster pulls
`quay.io/tjungbau/shop-catalog-dev:shop-test-dev` and `registry.redhat.io/ubi9/ubi:9.9`.

The files:

| File | Content |
|---|---|
| `kustomization.yaml` | catalog from the shop's `deploy/base` (one replica) with the dev image, plus `probe.yaml` |
| `probe.yaml` | Pod `probe` (UBI 9 with `curl`): `GET /products` every 0.2 s, one line `<time> <status>` |
| `spread.yaml` | strategic-merge patch for catalog: 3 replicas, spread constraints, `maxSurge 1` / `maxUnavailable 0`, `preStop` sleep 5 s |
| `pdb.yaml` | PodDisruptionBudget `catalog`, `minAvailable: 2` |

The `preStop` uses the built-in `sleep` action (`lifecycle.preStop.sleep.seconds`) – no `sleep`
binary needed in the image. The script counts the probe's answers per status with
`oc logs probe --since-time=…`.
