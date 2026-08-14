# Runbook

Installing the operators and the chart. Audience: someone comfortable with Kubernetes,
Helm, and CRDs.

Companion docs: [sizing.md](sizing.md) for capacity, [AGENTS.md](../AGENTS.md) for design
rationale and accumulated gotchas.

---

## 0. What you're signing up for

Two operators (installed once per cluster, cluster-scoped) and one Helm release per
environment. The operators own CRDs, so their lifecycle is deliberately separate from the
application. `helm uninstall` on the app must never be able to remove a CRD another team
depends on.

| Layer | Owns | Who installs |
|---|---|---|
| `clickstack-operators` | `ClickHouseCluster`, `KeeperCluster`, and (bundled) MCK | Cluster admin, once |
| `hyperdx` (this chart) | CRs + two stateless Deployments | App owner, per namespace |

---

## 1. Install the operators

**Both operators come from one chart.** `clickstack-operators` bundles MongoDB Controllers
for Kubernetes (MCK) alongside the ClickHouse operator. Installing
`mongodb/mongodb-kubernetes` separately will fail on ClusterRole ownership conflicts — it's
already there.

```bash
helm repo add clickstack https://clickhouse.github.io/ClickStack-helm-charts
helm repo update

helm install clickstack-operators clickstack/clickstack-operators \
  --namespace clickhouse --create-namespace \
  --set-string 'mongodb-operator.operator.watchNamespace=*' \
  --wait --timeout 10m
```

### The `watchNamespace` flag is not optional

By default the bundled MCK sets `WATCH_NAMESPACE` to its own install namespace. If you
deploy HyperDX into any *other* namespace, the operator never sees your `MongoDBCommunity`
resource. There is no error — the CR simply sits with an empty `PHASE` forever, and the
`hyperdx` pod waits in its init container.

Set it at install time. **Changing it later via `helm upgrade` fails**, because the chart's
RoleBindings have immutable `roleRef` fields:

```
RoleBinding "mongodb-kubernetes-operator" is invalid:
  roleRef: Invalid value: ... cannot change roleRef
```

Recovering from that means deleting the RoleBindings and re-running the upgrade, or
patching the Deployment env directly. Get it right the first time.

Scope it explicitly if you'd rather not grant cluster-wide watch:

```bash
--set-string 'mongodb-operator.operator.watchNamespace=observability\,staging'
```

### Verify

```bash
kubectl get crd | grep -E 'clickhouse.com|mongodbcommunity'
```

Expect:

```
clickhouseclusters.clickhouse.com
keeperclusters.clickhouse.com
mongodbcommunity.mongodbcommunity.mongodb.com
```

Both controllers land in the operator namespace:

```bash
kubectl get pods -n clickhouse
```

Confirm the watch scope actually took:

```bash
kubectl get deploy mongodb-kubernetes-operator -n clickhouse \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WATCH_NAMESPACE")].value}'
```

### A note on the MongoDB CRDs

MCK registers several CRDs. **Use only `MongoDBCommunity`** — that is the free path and
needs no Ops Manager. `MongoDB` and `MongoDBMultiCluster` (`mongodb.com/v1`) are the
Enterprise resources and require MongoDB Enterprise Advanced licensing. The chart only ever
creates `MongoDBCommunity`.

---

## 2. Install the chart

```bash
helm install o11y ./charts/hyperdx \
  --namespace observability --create-namespace \
  --set hyperdx.publicUrl=https://hyperdx.example.com \
  -f charts/hyperdx/values-small.yaml
```

Pick the profile that matches your hardware — see [sizing.md](sizing.md). The defaults
assume roughly 4 vCPU / 8 GB and **will not schedule** on a 2 vCPU / 4 GB node.

### Expected convergence order

Nothing is instant. Roughly:

1. Keeper `StatefulSet` starts and reports `Standalone Keeper is ready` (~30s)
2. ClickHouse operator runs a **version-probe pod** against the configured image
3. ClickHouse `StatefulSet` starts once the probe succeeds
4. MCK reconciles `MongoDBCommunity`, generating the SCRAM and connection-string Secrets
5. `hyperdx` and `otel-collector` init containers stop blocking and the Deployments roll

Watch it:

```bash
kubectl get clickhousecluster,keepercluster,mongodbcommunity -n observability -w
```

Two to five minutes on a warm cluster with images cached. First install on a slow
connection is longer — the ClickHouse and HyperDX images are large.

### Verify

```bash
kubectl get pods -n observability
helm test o11y -n observability
kubectl port-forward -n observability svc/o11y-hyperdx 8080:8080
```

---

## 3. Credentials

By default the chart generates the session secret, both ClickHouse passwords, and the
MongoDB password on first install, then reuses them on upgrade via `lookup`. The Secret
carries `helm.sh/resource-policy: keep` so it survives an uninstall.

Two things to know:

- **`EXPRESS_SESSION_SECRET` must always be set.** Upstream falls back to a known hardcoded
  development string if it is empty.
- **Rotating it logs out every user.** Rotating a database password breaks the running
  deployment until pods restart.

To manage credentials yourself:

```yaml
auth:
  existingSecret: hyperdx-auth          # keys: express-session-secret, api-key
clickhouse:
  auth:
    existingSecret: hyperdx-ch          # keys: clickhouse-collector-password,
                                        #       clickhouse-app-password
mongodb:
  existingSecret: hyperdx-mongo         # key: mongodb-password
```

### ClickHouse passwords are visible in the CR

The official ClickHouse operator has no per-user `secretKeyRef` (Altinity's does), so user
passwords render into `ClickHouseCluster.spec.settings.extraUsersConfig`. Anyone with read
access to that resource can read them. Restrict RBAC on `clickhouseclusters` accordingly.

`spec.settings.defaultUserPassword` *can* source from a Secret, but only for the `default`
user, which the chart does not use for the application.

---

## 4. GitOps / Argo CD

The chart works under Argo CD, with one hard requirement and two conveniences.

### You must externalize secrets

Argo CD renders with `helm template` and **no cluster access**, so Helm's `lookup` function
always returns nil. The generation helper therefore falls through to `randAlphaNum` on
*every sync*, which means:

- ClickHouse passwords rotate continuously and the collector can't authenticate
- the session secret rotates and logs out every user
- the Application is permanently `OutOfSync` on the Secret

Set all three `existingSecret` values and manage them with External Secrets Operator,
Sealed Secrets, or whatever you already run. This is not optional.

### Ordering

Operators must reconcile before the CRs are applied. Two Applications:

```yaml
# operators
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
---
# hyperdx
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

Add `ServerSideApply=true` if you hit CRD size limits.

### Health checks

Argo CD has no built-in health assessment for these CRs, so the Application sits
`Progressing` indefinitely. Add to `argocd-cm`:

```yaml
resource.customizations.health.clickhouse.com_ClickHouseCluster: |
  hs = {}
  hs.status = "Progressing"
  hs.message = "Reconciling"
  if obj.status ~= nil and obj.status.ready == "True" then
    hs.status = "Healthy"
    hs.message = obj.status.status or "Ready"
  end
  return hs

resource.customizations.health.mongodbcommunity.mongodb.com_MongoDBCommunity: |
  hs = {}
  hs.status = "Progressing"
  hs.message = "Reconciling"
  if obj.status ~= nil and obj.status.phase == "Running" then
    hs.status = "Healthy"
    hs.message = "Running"
  end
  return hs
```

Finally, keep Argo CD from pruning the retained Secret:

```yaml
argocd.argoproj.io/sync-options: Prune=false
```

---

## 5. Upgrades

Bumping the chart is routine. Bumping `appVersion` to a new upstream HyperDX release is not.

Before promoting an upstream bump, diff these three paths between the current and target
upstream revision:

```
docker/otel-collector/schema/seed/     # collector-owned, idempotent
packages/api/migrations/ch/            # versioned, ONE-WAY
packages/api/migrations/mongo/         # versioned, ONE-WAY
```

Empty diff means it's safe. Non-empty means read it before promoting. The
`upstream-check` workflow does this automatically and opens an issue.

### Why the diff matters

The collector applies its ClickHouse schema as `CREATE TABLE IF NOT EXISTS` with **no
version tracking**. It will never destroy data — and it will never migrate an existing
table either. A changed column type, codec, or engine silently does not apply. The upgrade
looks clean while your schema quietly drifts from what the new collector expects.

The API migrations, by contrast, are versioned and irreversible.

### Retention changes are not retroactive

`otelCollector.tablesTtl` is applied at table creation. Changing it later does not rewrite
the TTL on existing tables — you need `ALTER TABLE ... MODIFY TTL` by hand. Decide
retention before first install.

---

## 6. Troubleshooting

### `Init:CreateContainerConfigError`

```
container has runAsNonRoot and image will run as root
```

The pod requires non-root but an init image defaults to root. The chart pins
`runAsUser: 65534` on its init containers; if you have overridden `podSecurityContext` or
`securityContext`, make sure a `runAsUser` survives.

### ClickHouse never starts, `version-probe` pod `OOMKilled`

The operator runs a short-lived probe pod against the configured ClickHouse image to detect
its version. Its memory limit is set by the operator, not this chart. If it OOMs, ClickHouse
never proceeds and the cluster reports `Cannot probe replicas`.

Most often seen on arm64 and constrained nodes. Check:

```bash
kubectl get pods -n observability | grep version-probe
kubectl describe pod -n observability <version-probe-pod>
```

### `MongoDBCommunity` stuck with empty `PHASE`

The operator is not watching your namespace. See §1 — this is the single most common
install failure. Confirm `WATCH_NAMESPACE` and check the operator log:

```bash
kubectl logs -n clickhouse -l app.kubernetes.io/name=mongodb-kubernetes-operator --tail=50
```

### App can't authenticate to MongoDB

The generated connection string must target the application database, not `admin`. The
chart sets the user's `db` to `mongodb.database` precisely so the URI carries the right
auth source. If you overrode it to `admin`, the URI omits `authSource=admin` and Mongoose
fails.

```bash
kubectl get secret -n observability o11y-hyperdx-mongo-connection \
  -o jsonpath='{.data.connectionString\.standardSrv}' | base64 -d
```

### Collector `OOMKilled`

Its internal `memory_limiter` sits around 1.5 GiB. If the container limit is at or below
that, the kernel kills it before the limiter can apply backpressure. Keep
`otelCollector.resources.limits.memory` above 2Gi even on small nodes — limits are not
reserved, so this is free when idle.

### Pods `Pending`

Requests exceed allocatable. Use a smaller profile:

```bash
kubectl describe node | grep -A6 "Allocated resources"
```

### Nothing appears in the UI

Check the collector reached ClickHouse and created its schema:

```bash
kubectl logs -n observability -l app.kubernetes.io/component=otel-collector --tail=50
kubectl exec -n observability -it <clickhouse-pod> -- clickhouse-client --query "SHOW TABLES"
```

---

## 7. Uninstall

```bash
helm uninstall o11y -n observability
```

Deliberately left behind:

- **PVCs.** Operator-managed volumes are not garbage collected. Delete them explicitly.
- **The chart Secret**, via `helm.sh/resource-policy: keep`, so a reinstall keeps working
  credentials.

```bash
kubectl get pvc -n observability
kubectl delete pvc -n observability --all      # destroys all telemetry and metadata
kubectl delete secret o11y-hyperdx -n observability
```

**Do not uninstall the operators** unless you are certain nothing else in the cluster uses
them. Removing the chart takes their CRDs with it, which will delete every
`ClickHouseCluster` and `MongoDBCommunity` in every namespace.
