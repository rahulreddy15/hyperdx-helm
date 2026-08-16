# hyperdx-helm

A Helm chart for [HyperDX](https://github.com/hyperdxio/hyperdx) — the open-source
observability platform (logs, traces, metrics, session replay) built on ClickHouse and
OpenTelemetry, now branded **ClickStack**.

Stateful backends are **operator-managed**: ClickHouse via the official ClickHouse
operator, MongoDB via MongoDB Controllers for Kubernetes (MCK).

> **Status: early but validated.** Verified end to end on a live cluster — a clean-room
> install brings up all five components, the collector creates its ClickHouse schema, and
> OTLP data sent to `:4318` is queryable from ClickHouse. Not yet run in production, and
> only single-node ClickHouse has been exercised. Treat `0.1.x` as a preview.

## Why this chart

`hyperdxio/helm-charts` was archived in March 2026 and development moved to
[ClickStack-helm-charts](https://github.com/ClickHouse/ClickStack-helm-charts). That chart
is the official option and a good default.

This one differs in a few opinions:

- **Secrets stay out of rendered manifests.** The ClickHouse password is not passed as a
  plain env value inside `DEFAULT_CONNECTIONS`.
- **Generated passwords survive `helm upgrade`** instead of rotating and breaking the
  deployment or logging everyone out.
- **Operators are strictly prerequisites**, never bundled — so `helm uninstall` can't take
  out CRDs other workloads depend on.
- **Bring-your-own backends are first-class.** Point at an existing ClickHouse or MongoDB
  and the chart deploys only the stateless parts.

If you don't need any of that, use the official chart.

## Requirements

- Kubernetes >= 1.27
- Helm >= 3.13
- [ClickHouse operator](https://github.com/ClickHouse/clickhouse-operator) — provides
  `clickhouse.com/v1alpha1`
- [MongoDB Controllers for Kubernetes](https://github.com/mongodb/mongodb-kubernetes) —
  provides `mongodbcommunity.mongodb.com/v1`

Both operators are cluster-scoped and install their own CRDs. Install them once per
cluster, separately from this chart.

<details>
<summary>Installing the operators</summary>

Both operators ship in **one** chart — `clickstack-operators` bundles MCK alongside the
ClickHouse operator. Installing `mongodb/mongodb-kubernetes` separately will fail on
ClusterRole ownership conflicts.

```bash
helm repo add clickstack https://clickhouse.github.io/ClickStack-helm-charts
helm install clickstack-operators clickstack/clickstack-operators \
  --namespace clickhouse --create-namespace \
  --set-string 'mongodb-operator.operator.watchNamespace=*'
```

`watchNamespace` is **not optional** if you deploy into a different namespace than the
operators, and it cannot be changed later by `helm upgrade` (immutable `roleRef`). See the
[runbook](docs/runbook.md).

</details>

Either backend can be skipped entirely — set `clickhouse.enabled=false` or
`mongodb.enabled=false` and supply connection details. You then don't need that operator.

## Install

```bash
helm install o11y ./charts/hyperdx \
  --namespace observability --create-namespace \
  --set hyperdx.publicUrl=https://hyperdx.example.com \
  --set ingress.enabled=true \
  --set ingress.host=hyperdx.example.com
```

Everything else has a working default. Passwords and the session secret are generated on
first install and preserved across upgrades.

### Sending telemetry

**Register a user first.** A freshly installed stack accepts no telemetry — the collector
comes up healthy but does not listen on 4317/4318 at all. HyperDX only wires the OTLP
receiver into the collector's pipelines once a team with an API key exists, and teams are
created by registration. See the [runbook](docs/runbook.md) for the headless call.

Once a team exists, OTLP senders must pass that team's API key in an `authorization`
header, or the collector returns 401.

The collector accepts OTLP on `4317` (gRPC) and `4318` (HTTP). In-cluster:

```
http://o11y-hyperdx-otel-collector.observability.svc.cluster.local:4318
```

For senders outside the cluster, enable `otlpIngress`. Note that OTLP **HTTP** works
through a standard Ingress; **gRPC** usually needs controller-specific annotations or a
LoadBalancer Service.

## Architecture

Two stateful backends. That's the whole dependency list — no Redis, no Postgres, no Kafka.

| Component | Kind | Purpose |
|---|---|---|
| `hyperdx` | Deployment | Next.js UI + API + OpAMP server |
| `otel-collector` | Deployment | Ingest, process, write to ClickHouse |
| `ClickHouseCluster` + `KeeperCluster` | CR | Telemetry storage |
| `MongoDBCommunity` | CR | Users, dashboards, saved searches, alert rules |
| alert checker | CronJob | Optional; alerts run in-process by default |

Lose ClickHouse and you lose telemetry history. Lose MongoDB and you lose dashboards and
logins, but the telemetry survives.

A `KeeperCluster` is deployed even for a single-node ClickHouse — the official operator
requires `keeperClusterRef` unconditionally.

## Configuration

See [`charts/hyperdx/values.yaml`](charts/hyperdx/values.yaml) for the full annotated set.
The values most people touch:

| Value | Default | Notes |
|---|---|---|
| `hyperdx.publicUrl` | `""` | Public URL including scheme. Set this. |
| `hyperdx.image.tag` | chart `appVersion` | Pin `hyperdx.image.digest` in production |
| `clickhouse.enabled` | `true` | `false` → use `clickhouse.external.*` |
| `clickhouse.storage.size` | `50Gi` | Sized by ingest volume × retention |
| `clickhouse.version` | `26.5-alpine` | Schema behaviour differs below 26.2 |
| `mongodb.enabled` | `true` | `false` → use `mongodb.external.*` |
| `mongodb.members` | `3` | `1` is fine for dev, gives no failover |
| `otelCollector.tablesTtl` | `720h` | Drives ClickHouse storage more than anything else |
| `auth.sessionSecret` | generated | Never leave unset — upstream falls back to a known dev string |
| `ingress.enabled` | `false` | UI/API ingress |
| `otlpIngress.enabled` | `false` | Separate ingress for external telemetry senders |

### Using existing backends

```bash
helm install o11y ./charts/hyperdx \
  --set clickhouse.enabled=false \
  --set clickhouse.external.host=clickhouse.internal \
  --set mongodb.enabled=false \
  --set mongodb.external.connectionStringSecret=my-mongo-conn
```

## Upgrading

Two things to know before bumping `appVersion`.

**The collector does not migrate existing tables.** Its seed SQL is idempotent
`CREATE TABLE IF NOT EXISTS` with no version tracking. It will never destroy data, but a
changed column type or codec silently won't apply to tables that already exist. Upgrades
look clean while schema quietly drifts.

**The API migrations are one-way.** `packages/api/migrations/ch/` and
`packages/api/migrations/mongo/` are versioned and not reversible.

So before promoting an upstream bump, diff those three directories between the current and
target upstream revision. Empty diff means it's safe. Non-empty means read it first.

Upstream releases roughly weekly with per-package Changesets tags
(`@hyperdx/app@2.34.0`) — there is no single monorepo version.

## Backups

MCK Community has no backup integration. A 3-member replica set is availability, not
backup — it won't save you from an accidental delete.

Back up MongoDB (dashboards, users, alert rules) with Velero, CSI snapshots, or a scheduled
`mongodump`. ClickHouse is usually reconstructible from re-ingested telemetry, so most
people accept its loss; if you can't, snapshot the PVC.

## Security notes

- `otelCollector.enableDatadogReceiver` opens an **unauthenticated** receiver. Off by
  default. Leave it off unless you've made a deliberate ingress and NetworkPolicy decision.
- ClickHouse user passwords render into the `ClickHouseCluster` CR. The official operator
  has no `secretKeyRef` for users (Altinity's does). Restrict RBAC on that resource.
- `hyperdx.usageStatsEnabled` is `false` by default here.
- Upstream images are **not** cosign-signed. The collector image also ships without SBOM or
  provenance attestations. Sign on ingest if that matters to you.

## Contributing

```bash
helm lint charts/hyperdx
helm template t charts/hyperdx > /dev/null
```

Every values file under `charts/hyperdx/ci/` must render cleanly. See
[AGENTS.md](AGENTS.md) for design decisions, upstream tracking, and the accumulated
gotchas — read it before making changes.

## License

[Apache 2.0](LICENSE). HyperDX itself is licensed separately by its authors.
