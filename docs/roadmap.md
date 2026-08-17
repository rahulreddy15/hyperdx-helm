# Roadmap

What this chart could grow next, in rough priority order. Items land here when they are
understood well enough to build but deliberately not built yet. Decision as of
2026-08-18: **single-node ClickHouse is sufficient for current needs** — the replication
feature below is de-risked and parked, waiting on us or upstream.

## ClickHouse replication (parked, fully de-risked)

Single-node ClickHouse is the shipped design. The complete path to `replicas: 2` was
verified live — evidence and design in [replication.md](replication.md). Build list when
we pick it up:

- `clickhouse.replicatedSchema.enabled` values flag; guard relaxed only for that
  combination (`shards > 1` stays refused unconditionally).
- Seeding init container on the collector pod: applies the per-`appVersion` DDL mirror
  (live-dumped, engines rewritten to no-arg `ReplicatedMergeTree`) as the collector's
  CH user over the HTTP interface, before the collector starts.
- DDL mirror as a ConfigMap + regeneration procedure; `upstream-check` extended to flag
  mirror staleness.
- Brownfield migration script/runbook (verified flow: pause collector → `INSERT SELECT`
  → `EXCHANGE TABLES`).
- CI: e2e variant with `replicas: 2` asserting per-pod count equality and failover
  convergence (phase scripts from the 2026-08-17 verification are the template).
- Untested corner to close: the `convert_to_replicated` flag-file migration path.

**Watch trigger — "implement accordingly when upstream fixes it":** the weekly
`upstream-check` workflow diffs `docker/otel-collector/schema/seed/` and opens an issue
on any drift. Two arrivals matter:

1. **Upstream seeds `ReplicatedMergeTree`** (or accepts an env-gated engine swap — the
   upstream issue we should file, citing replication.md): the mirror becomes
   unnecessary; the chart feature reduces to a values flag + guard change. Build it then.
2. **The `TimeSeries`-engine table (`metrics_ts`) and rollup MVs ship** (already on
   upstream `main`): `TimeSeries` has no Replicated variant — re-evaluate the design
   before enabling replication on that appVersion.

## ClickHouse on object storage (idea, unverified)

ClickHouse OSS supports S3-compatible storage for MergeTree data (full-S3 with a local
filesystem cache, or tiered hot-PVC/cold-S3 via TTL moves). Likely wireable through
`clickhouse.extraSettings` (→ server `storage_configuration`) plus a global
`<merge_tree><storage_policy>` default so the collector's seed tables inherit it with
zero DDL changes — **untested**. Caveats to verify: Keeper/metadata stay on PVC;
credentials render into the CR unless IAM/env-based; request-cost/latency profile needs
a cache disk; per-table TTL-move tiering is collector-owned DDL (same pre-seed story as
replication). Verification step: MinIO on the test cluster, ingest, restart, assert
parts on the bucket.

## Upstream issues to file

- Env-gated `ReplicatedMergeTree` seeding in ClickStack's collector seed SQL
  (justification: replication.md; Keeper is already mandatory under the operator, and
  replicated engines run fine single-node).
- `hdxMTViews.ts` (on-demand accelerator MVs, not yet active in 2.35.0) hardcodes plain
  `AggregatingMergeTree` with hash-derived names — unfixable chart-side; ask for
  engine/database configurability when it ships.

## Sharding

Not planned. Needs a `Distributed` layer plus app/collector awareness — upstream
application work. Revisit only if upstream builds it; until then the answer at that
scale is `clickhouse.enabled=false` + a real ClickHouse cluster.

## Production readiness

- **P0 — alert on data, shipped as manifests**: ServiceMonitors (collector `:8888`
  exporter metrics — verified truthful; ClickHouse `:9363`) and a PrometheusRule
  starter pack ("no rows written in N minutes", `send_failed > 0`, CH disk headroom).
- **P0 — backups that exist**: scheduled `mongodump` CronJob or Velero recipe, plus one
  rehearsed restore with measured RTO/RPO. MCK Community has no backup story.
- **P1 — soak test**: multi-hour sustained load including traces and metrics (load
  testing so far: 180 s, logs only).
- **P1 — upgrade playbook for a non-empty schema diff**: what to actually do when
  `upstream-check` reports drift (the current docs only say "read it first").
- **P1 — digest-pin automation**: refresh `values-production.yaml` image digests
  automatically in version-bump PRs.
- **P2 — SSO recipe**: oauth2-proxy in front of the UI (open-source HyperDX has local
  auth only).
- **P2 — operator compatibility record**: track which ClickHouse-operator / MCK versions
  the chart is tested against.

## Chart polish (small, queued)

- PodDisruptionBudget for the collector (app has one; CH/Keeper PDBs are
  operator-managed).
- Anti-affinity / topology-spread defaults in `values-production.yaml` (2× app and
  collector replicas currently co-schedulable).
- Complete `values.schema.json`: `alerting`, `podDisruptionBudget`, `serviceAccount`,
  `commonLabels`, `commonAnnotations` blocks are unvalidated today.
- Drop the Enterprise-only `mongodb-kubernetes-database-pods` ServiceAccount from
  `mongodb-rbac.yaml`.

## Verification debt

- First real GitHub Actions run of `.github/workflows/e2e.yaml` (never executed in CI —
  all work went straight to main; fires on the next PR or via manual dispatch).
- NetworkPolicy behavior on a CNI that actually enforces it (minikube's does not —
  policies are spec-verified only).
- Bootstrap registration failure path (non-2xx/non-409) never exercised live.
