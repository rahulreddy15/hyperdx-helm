# ClickHouse replication and sharding: what was tested, what works

The chart refuses `clickhouse.replicas` or `clickhouse.shards` above 1. This document is
the evidence behind that guard — and behind the path that could lift it for replication.
Everything here was verified live on 2026-08-17 (chart 0.4.x working tree, appVersion
2.35.0, ClickHouse 26.5.6, official operator, minikube) in a five-phase test: DDL
authorship, seed-race semantics, an engine matrix at 2 replicas, full-schema replication
with failover, and a 2-shard failure-signature run.

## The one-sentence version

ClickHouse and the operator already support replication and sharding; **HyperDX's seed
schema does not** — its tables are plain `MergeTree`, and data replication in ClickHouse
is a property of the table engine. Replication is fixable from the chart (verified end to
end); sharding is not fixable without upstream application changes.

## Who creates the schema (verified, not assumed)

- **The app creates zero ClickHouse objects** — before registration, after registration,
  ever. Its ClickHouse user (`app`) holds no DDL grants at all.
- **Everything comes from the collector**: 9 tables + 1 materialized view (2.35.0), all
  plain `MergeTree` with a TTL, created by a goose runner **with no version tracking** —
  the seed SQL is `CREATE ... IF NOT EXISTS`, re-applied on every collector start.
- Consequence: pre-created tables win. A table that already exists is left completely
  alone by the collector, whatever its engine.

## Why `replicas: 2` is refused today

With the stock schema, the operator's `Replicated` database copies **DDL** to every
replica — so all tables exist everywhere and every pod is Ready — but `MergeTree` data
stays on whichever replica received the insert. Observed: `system.replicas` empty,
counts through the Service flapping between divergent replicas. Split-brain that passes
every health check.

## The verified path to replication (1 shard × N replicas)

Pre-seed the schema with `ReplicatedMergeTree` engines **before the collector's first
start**. Every step of this was exercised live:

- **Engine form**: no-argument `ReplicatedMergeTree` only. The explicit
  `('/clickhouse/tables/...','{replica}')` form from the ClickHouse deployment guides is
  **refused** inside the operator's `Replicated` database (CH 26.5). The derived path is
  `/clickhouse/tables/{table-uuid}/{shard}`.
- **Mechanism**: an init container on the collector pod (a `wait-for-clickhouse` init
  container already exists there), running as the **collector's** ClickHouse user — the
  only user with DDL grants. A pre-install hook cannot work: hooks run before manifests,
  so ClickHouse does not exist yet.
- **What then works** (all observed): collector seed no-ops against the pre-seeded
  schema; ingest replicates to all replicas; a replica added *later* syncs the full
  history; MVs into replicated targets stay identical on all pods; killing a replica
  mid-ingest loses **zero** records (client saw uninterrupted 2xx; replicas reconverged
  exactly); a full rolling restart stays consistent; reads through the Service are
  stable.
- **Bonus semantic**: Replicated tables deduplicate byte-identical insert blocks —
  duplicate-protection for retried exports. Irrelevant for real (unique) telemetry.
- **The cost**: the chart must carry an exact DDL mirror per `appVersion`, refreshed from
  a live dump (not from upstream `main`, which already diverges — it adds a
  `TimeSeries`-engine table that has **no** Replicated variant, plus new rollup MVs).
  The mirror turns the weekly upstream schema diff from "review" into "mandatory
  maintenance".
- **The cheaper fix is upstream**: an env-gated engine swap in ClickStack's seed SQL
  (`MergeTree` → `ReplicatedMergeTree`) would delete the mirror entirely. Replicated
  engines run fine on single-node — this repo's Keeper is mandatory anyway.

If the seed mirror is ever wrong (missing column), the failure is loud, not silent: the
new collector pod crash-loops at `0/1` while the previous pod keeps serving, and it
self-heals seconds after the schema is corrected (see the runbook's troubleshooting
entry).

## Migrating an existing install (brownfield — verified with data)

Per table, with the collector scaled to 0:

```sql
CREATE TABLE default.otel_logs_r ( ...same columns/ORDER BY/TTL... )
  ENGINE = ReplicatedMergeTree ...;
INSERT INTO default.otel_logs_r SELECT * FROM default.otel_logs;
EXCHANGE TABLES default.otel_logs AND default.otel_logs_r;
DROP TABLE default.otel_logs_r SYNC;
```

Rows were preserved exactly and replicated to the second pod; `EXCHANGE TABLES` is
atomic. (The `convert_to_replicated` flag-file mechanism was **not** tested.)

## Why sharding stays refused

Tested in the strongest form: 2 shards with a **fully replicated** schema. DDL propagated
to the new shard, but its tables form a separate replica set (`{shard}` macro in the
path), so history stays on shard 0, new writes pin to whichever shard holds the
collector's connection, and 12 consecutive reads through the Service returned
`45 45 45 0 0 45 0 0 45 0 0 0`. Replicated engines do not rescue sharding — it needs a
`Distributed` table layer **and** an app/collector that know to use it. That is upstream
application work. (A chart-side masquerade — seeding the well-known names as
`Distributed` tables over hidden locals — is technically conceivable via the same
IF-NOT-EXISTS mechanics, but it means maintaining a parallel storage architecture
upstream knows nothing about. Not worth it; at that scale, bring your own ClickHouse via
`clickhouse.enabled=false`.)

## Also learned along the way

- App-generated on-demand MVs (upstream `hdxMTViews.ts`, not active in 2.35.0) hardcode
  plain `AggregatingMergeTree` with hash-derived names — impossible to pre-seed;
  upstream-only fix when the feature ships.
- The collector's exporter metrics (`otelcol_exporter_sent_log_records`,
  `otelcol_exporter_send_failed_*` on `:8888/metrics`) were exactly truthful throughout
  failover testing — the right signal between "pod Ready" and "rows in ClickHouse".
- Test-harness trap: OTLP `timeUnixNano` must be exactly 19 digits. Malformed stamps
  land in 1975, and past-dated rows are TTL-dropped as whole parts
  (`ttl_only_drop_parts=1` drops a part only when *every* row in it is expired) — which
  is indistinguishable from ingest loss until you check the exporter metrics and
  `min(Timestamp)`.
