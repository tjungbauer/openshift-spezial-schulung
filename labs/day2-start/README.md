# Day 2 start – the shop into Git, Argo CD runs it (10 min)

From now on the shop runs the GitOps way: its Kustomize files live in **your** Git repository,
your Argo CD deploys them into a second namespace, `<your namespace>-shop`. Every lab of Day 2
changes the shop through a commit.

**Why a second namespace?** The shop closes its namespace with NetworkPolicies (default deny).
In your own namespace they would also cut off your Argo CD. The trainer has created
`$NS-shop` and labelled it so that your Argo CD may deploy there.

Run the commands from the **root of the training repository** (the folder that contains
`shop/` and `labs/`).

## 1 · Variables

```bash
export NS=user-01                                                   # your namespace
export SHOP_REPO=https://git.acme.example/user-01/shop-gitops.git   # an EMPTY repository
export GIT_USER=user-01
export SHOP_WORK=~/shop-gitops
oc project $NS
```

Create the empty repository `shop-gitops` in the web UI of the Git server first (no README).
Your token – typed, not shown:

```bash
printf 'Git token: '; read -rs GIT_TOKEN; echo
```

## 2 · The shop's deployment files into Git

```bash
mkdir -p "$SHOP_WORK"
cp -r shop/deploy/base shop/deploy/components shop/deploy/overlays "$SHOP_WORK"/
git -C "$SHOP_WORK" init -b main
git -C "$SHOP_WORK" config user.name "$NS"
git -C "$SHOP_WORK" config user.email "$NS@training.example"
git -C "$SHOP_WORK" add .
git -C "$SHOP_WORK" commit -m "shop: base, components, overlays"
git -C "$SHOP_WORK" remote add origin "$SHOP_REPO"
git -C "$SHOP_WORK" push -u origin main
```

**Expected result:** the push ends with `main -> main`.

## 3 · Read access for Argo CD and the Application

```bash
oc create secret generic shop-gitops-repo \
  --from-literal=type=git --from-literal=url="$SHOP_REPO" \
  --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN"
oc label secret shop-gitops-repo argocd.argoproj.io/secret-type=repository
cat labs/day2-start/application-shop-dev.yaml
sed -e "s|<NS>|$NS|g" -e "s|<REPO_URL>|$SHOP_REPO|" labs/day2-start/application-shop-dev.yaml | oc apply -f -
```

## 4 · Check

```bash
oc get applications.argoproj.io shop-dev                  # Synced / Healthy after 1-2 minutes
oc get pods -n $NS-shop
ROUTE=$(oc get route web -n $NS-shop -o jsonpath='{.spec.host}')
echo https://$ROUTE
```

**Expected result:** `shop-dev` is `Synced` and `Healthy`; five Pods run in `$NS-shop`; the shop
opens in the browser. In the Argo CD UI: the Application tile `shop-dev` with all objects.

> **What to notice:** you did not apply a single shop object. The Application in `$NS` points to
> `overlays/dev` in your repository – Argo CD does the rest, in another namespace.

**If it does not work**

- `… is forbidden … namespace "user-01-shop"` in the Application – the namespace is not prepared
  for your Argo CD. Ask the trainer (`day2-setup.sh`).
- `ComparisonError … authentication required` – the repository Secret is missing or wrong:
  `oc get secret shop-gitops-repo --show-labels`.
- `OutOfSync` on the ServiceMonitors – user workload monitoring is not enabled on the cluster.
  Ask the trainer.

## Trainer

Before Day 2, as cluster-admin, after `labs/lab-05/trainer/lab-05-setup.sh`:

```bash
./labs/day2-start/trainer/day2-setup.sh user-01 user-02 user-03
```
