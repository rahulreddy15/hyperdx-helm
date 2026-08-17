# Operations

Day-2 guidance: what to actually alert on, what load testing showed, how to upgrade
safely, what to back up, and the security surfaces to keep closed.

## Pod readiness lies here — alert on data, not on pods

Two probes on this stack pass while the thing they appear to vouch for is broken:

- The collector's readiness probe checks port 13133, which answers happily **with no
  pipeline running** — observed `1/1 Ready` for ten minutes while every send was refused.
- The app's `/health` returns 200 **with MongoDB entirely unreachable**.

Alert on rows arriving in ClickHouse. This is not hypothetical: in load testing, an
undersized collector refused 64% of traffic while Kubernetes reported it `Running`,
`Ready`, zero restarts, the whole time.

Between "pod Ready" and "rows in ClickHouse" sits one honest signal: the collector's own
exporter metrics on `:8888/metrics` — `otelcol_exporter_sent_log_records` and the
`send_failed`/`enqueue_failed` counters. During live failover testing they were exactly
truthful while everything else was ambiguous ([replication.md](replication.md)). Scrape
them.

## What load testing showed

The small profile (2 vCPU / 4 GB target) survived 180 s of sustained synthetic OTLP logs
with **zero loss** — 28.6 M records sent, 28.6 M in ClickHouse; overload surfaced as
HTTP 503 backpressure, not drops. But the margins were thin and the failure mode is
silent:

- **ClickHouse peaked 15 MiB under its 2 Gi limit.** Raise
  `clickhouse.resources.limits.memory` first if you expect sustained ingest.
- **Peak CPU (~2.2 vCPU) exceeded the profile's namesake.** On a real 2-core node it
  would have throttled.
- **Never set the collector memory limit at or below ~1.5 Gi** — that's where its
  internal `memory_limiter` sits. Below it, the collector fails silently while the pod
  stays green (the 64% episode above).

Don't quote the implied ~159k records/sec as capacity — the payload was synthetic and
highly compressible, and the host had 6 cores. Read it as "does not fall over", not as a
throughput rating. Methodology, caveats, and the generator script:
[load-testing.md](load-testing.md).

## Upgrading

Two things before bumping `appVersion`:

- **The collector never migrates existing tables.** Its seed SQL is idempotent
  `CREATE TABLE IF NOT EXISTS` with no version tracking — a changed column type or codec
  silently won't apply to tables that already exist.
- **The API migrations** (`packages/api/migrations/{ch,mongo}/`) are versioned; down
  migrations exist upstream, but rolling back a live schema is untested — treat them as
  forward-only in practice.

So the upgrade gate is a diff of those three upstream paths between current and target
versions: empty diff → safe; non-empty → read it first. The `upstream-check` workflow
runs this weekly and opens an issue. Upstream releases roughly weekly with per-package
Changesets tags (`@hyperdx/app@2.35.0`) — there is no single monorepo version.

## Backups

MCK Community has no backup integration — a 3-member replica set is availability, not
backup. Back up MongoDB (dashboards, users, alert rules) with Velero, CSI snapshots, or a
scheduled `mongodump`. ClickHouse is usually reconstructible from re-ingested telemetry;
if you can't accept its loss, snapshot the PVC.

## Security notes

- ClickHouse user passwords render into the `ClickHouseCluster` CR — the official
  operator has no `secretKeyRef` for users (Altinity's does). Restrict RBAC on that
  resource.
- Fluent Forward (24225) and the optional Datadog receiver are the unauthenticated
  surfaces. With `networkPolicy.enabled=true` the fluentd port is **denied by default**
  and only opens to peers you list in `networkPolicy.fluentdIngressFrom`; telemetry and
  UI/API sources can be restricted with `telemetryIngressFrom` / `appIngressFrom`.
- `hyperdx.usageStatsEnabled` defaults to `false` here.
- Upstream images are **not** cosign-signed, and the collector image ships without
  SBOM/provenance attestations. Sign on ingest if that matters to you.
