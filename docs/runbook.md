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
  --set clickhouse.auth.collectorPassword="$(openssl rand -base64 24)" \
  --set clickhouse.auth.appPassword="$(openssl rand -base64 24)" \
  -f charts/hyperdx/values-small.yaml
```

The two ClickHouse passwords are **required on first install** (or supply
`clickhouse.auth.existingSecret`) — see §3. Everything else has a working default.

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

### First run: telemetry does not flow until someone registers

This surprises everyone, so it is worth stating plainly:

> **A freshly installed stack accepts no telemetry.** The collector starts, reports
> healthy, and does not listen on 4317 or 4318 at all.

HyperDX generates the collector's pipeline configuration and pushes it over OpAMP. In
`packages/api/src/opamp/controllers/opampController.ts` the OTLP receiver is attached only
when at least one team has an API key:

```ts
if (apiKeys && apiKeys.length > 0) {
  pipelines.traces.receivers.push('otlp/hyperdx');
  pipelines.metrics.receivers.push('otlp/hyperdx');
  pipelines['logs/in'].receivers.push('otlp/hyperdx');
}
```

Teams are created by user registration. Until then the delivered pipelines receive only
from `fluentforward`, the `prometheus` scrape receiver, and `nop` — the OTLP ports are
never bound.

Register the first user — through the UI, or headlessly:

```bash
curl -X POST http://<hyperdx>:8000/register/password \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"...","confirmPassword":"..."}'
```

Within about a minute the supervisor picks up the new config and 4317/4318 start
listening. Confirm:

```bash
kubectl exec -n observability deploy/o11y-hyperdx-otel-collector -- \
  netstat -ltn | grep -E '4317|4318'
```

### OTLP requires the team API key

Registration also sets `collectorAuthenticationEnforced: true` on the new team, so every
OTLP sender must present that key. Unauthenticated sends return **401**.

```bash
kubectl exec -n observability o11y-hyperdx-mongodb-0 -c mongod -- \
  mongosh "mongodb://<user>:<pass>@localhost:27017/hyperdx" --quiet \
  --eval 'db.teams.find({},{apiKey:1}).toArray()'
```

Send with it in an `authorization` header:

```bash
curl -X POST http://<collector>:4318/v1/logs \
  -H 'Content-Type: application/json' \
  -H 'authorization: <team-api-key>' \
  -d '{"resourceLogs":[...]}'
```

There is no supported way to pre-provision a team unattended. If you need fully hands-off
GitOps bring-up, script the registration call as a post-install step.

### A Ready collector does not mean ingestion works

The readiness probe checks the health-check extension on 13133, which comes up even when no
OTLP receiver is wired and no pipeline is running. During testing the collector sat at
`1/1 Ready` for over ten minutes while dropping every attempt to send data.

Check the ports, not the pod status.

---

## 3. Credentials

The chart generates the session secret and the MongoDB password on first install, then
reuses them on upgrade via `lookup`. The Secret carries `helm.sh/resource-policy: keep`
so it survives an uninstall.

The **ClickHouse passwords are the exception: you must supply them on first install**
(flags or `clickhouse.auth.existingSecret`; the render fails otherwise). They land in two
independently rendered places — the chart Secret and the `ClickHouseCluster` CR — and Helm
does not memoize helper results, so a generated random value would differ between the two
and provision ClickHouse with credentials the app and collector never send. Once
installed, they are retained across upgrades like everything else.

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
always returns nil.

The chart now fails the render outright if ClickHouse credentials are neither supplied nor
backed by an existing Secret, so you will not silently get rotating passwords. But it does
mean **you cannot run this chart under Argo CD with generated credentials at all**. You
must supply them:

```yaml
auth:
  existingSecret: hyperdx-auth          # key: express-session-secret
clickhouse:
  auth:
    existingSecret: hyperdx-ch          # keys: clickhouse-collector-password,
                                        #       clickhouse-app-password
mongodb:
  existingSecret: hyperdx-mongo         # key: mongodb-password
```

Manage those with External Secrets Operator, Sealed Secrets, or whatever you already run.
If a referenced key is missing the render fails with a message naming the Secret and key —
it will not fall back to a placeholder.

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
packages/api/migrations/ch/            # versioned
packages/api/migrations/mongo/         # versioned
```

Empty diff means it's safe. Non-empty means read it before promoting. The
`upstream-check` workflow does this automatically and opens an issue.

### Why the diff matters

The collector applies its ClickHouse schema as `CREATE TABLE IF NOT EXISTS` with **no
version tracking**. It will never destroy data — and it will never migrate an existing
table either. A changed column type, codec, or engine silently does not apply. The upgrade
looks clean while your schema quietly drifts from what the new collector expects.

The API migrations, by contrast, are versioned (down migrations exist upstream, but
rolling back a live schema is untested — treat them as forward-only in practice).

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

### ClickHouse crash-loops with `Coordination error: Not authenticated`

```
Code: 999. Coordination::Exception: Coordination error: Not authenticated,
path /clickhouse/sessions/zookeeper/... (KEEPER_EXCEPTION)
```

ClickHouse cannot authenticate to Keeper. Seen when Keeper starts before the operator
finishes templating the cluster secret — the operator logs
`version probe is not completed yet, skipping cluster secret templating` during that
window, so Keeper comes up without the credential ClickHouse later presents.

Restart Keeper, then ClickHouse:

```bash
kubectl delete pod -n <ns> <release>-keeper-keeper-0-0
# wait for it to be Running, then
kubectl delete pod -n <ns> <release>-clickhouse-0-0-0
```

Intermittent, and it does not always self-heal through CrashLoopBackOff.

### App can't authenticate to external MongoDB

```
MongoServerError: Authentication failed. (code 18)
MongooseError: Operation `teams.find()` buffering timed out after 10000ms
```

Almost always `authSource`. It must name the database the user was **created in**, not the
one you're connecting to:

```
mongodb://u:p@host:27017/hyperdx?authSource=hyperdx    # user created in hyperdx
mongodb://u:p@host:27017/hyperdx?authSource=admin      # user created in admin
```

Verify the URI independently before blaming the chart:

```bash
kubectl run mtest --rm -i --restart=Never -n <ns> --image=mongo:8.0 -- \
  mongosh "<your-uri>" --quiet --eval 'print(db.runCommand({ping:1}).ok)'
```

Note the app's `/health` endpoint returns **200 even with MongoDB entirely unreachable**,
so the pod will sit `1/1 Ready` while nothing works. Check app logs, not pod status.

Also confirm the value actually reached the container — `helm get values <release>` and
`kubectl exec ... -- sh -c 'echo $MONGO_URI'`. A failed `helm install` that hit
`cannot re-use a name that is still in use` leaves the *previous* release's values in
place, which looks identical to a chart bug.

### Nothing appears in the UI

Work through these in order — the first is by far the most common:

1. **Has anyone registered?** No team means no OTLP receiver. Check the collector is
   actually listening:
   ```bash
   kubectl exec -n observability deploy/o11y-hyperdx-otel-collector -- \
     netstat -ltn | grep -E '4317|4318'
   ```
   Nothing listed → see "First run" above. The pod will still report `1/1 Ready`.

2. **Are senders passing the API key?** Unauthenticated OTLP returns 401 once a team
   exists.

3. **Did the collector create its schema?**
   ```bash
   kubectl exec -n observability <clickhouse-pod> -- \
     clickhouse-client --user <collector-user> --password <pw> --query "SHOW TABLES FROM default"
   ```
   Expect `otel_logs`, `otel_traces`, `otel_metrics_*`, `hyperdx_sessions`. Missing tables
   usually mean a grants problem — check the collector's own log, which the supervisor does
   **not** forward to pod logs:
   ```bash
   kubectl exec -n observability <collector-pod> -- \
     tail -50 /etc/otel/supervisor-data/agent.log
   ```

4. **Is data in ClickHouse but not on screen?** Then the problem is UI sources, not
   ingestion. Confirm `DEFAULT_SOURCES` was applied and points at the right database.

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

**Uninstalling this chart is safe** — it contains no CRDs and has no chart dependencies,
so it cannot remove anything cluster-scoped.

**Uninstalling `clickstack-operators` is not.** That release owns the CRDs, and removing it
deletes every `ClickHouseCluster`, `KeeperCluster`, and `MongoDBCommunity` in *every*
namespace, along with the data behind them. Do not do it unless you are certain nothing
else in the cluster uses those operators.
