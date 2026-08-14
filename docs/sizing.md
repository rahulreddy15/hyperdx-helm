# Sizing

How much cluster you need, and how to run this on very little.

## TL;DR

| Profile | vCPU | RAM | Disk | Values file |
|---|---:|---:|---:|---|
| Minimum viable | 2 | 4 GB | 20 GB | [`values-small.yaml`](../charts/hyperdx/values-small.yaml) |
| Default (chart defaults) | 4 | 8 GB | 120 GB | — |
| Production | 8+ | 32 GB+ | 500 GB+ | [`values-production.yaml`](../charts/hyperdx/values-production.yaml) |

The chart defaults target a small-but-real deployment. **They do not fit on a 2 vCPU / 4 GB
node** — use `values-small.yaml` for that.

---

## Understanding the constraint

Kubernetes schedules on **requests**, not limits. A pod is placed if its memory *request*
fits in allocatable memory; it is OOM-killed only if actual usage exceeds its *limit*.

This distinction is the whole trick to running on small nodes:

> **Lower the requests. Leave the limits high.**

A collector with `requests.memory: 256Mi` and `limits.memory: 2Gi` schedules on a tiny node
and still has headroom to burst. It only dies if it genuinely uses 2 GB — which at low
ingest volume it never will.

Also note a 4 GB node does not give you 4 GB. Kubelet and system reserves take roughly
0.5 vCPU and 1 GB, so plan against **~1.5 vCPU and ~3 GiB allocatable**.

---

## What the chart defaults request

| Component | CPU | Memory | Disk |
|---|---:|---:|---:|
| hyperdx | 200m | 512Mi | — |
| otel-collector | 200m | 512Mi | — |
| ClickHouse | 500m | 2Gi | 50Gi |
| Keeper | 100m | 256Mi | 10Gi |
| MongoDB × 3 | 600m | 1536Mi | 60Gi |
| **Total** | **1.6** | **4.75 GiB** | **120 GiB** |

Roughly a 4 vCPU / 8 GB node with 120 GB of storage.

---

## Minimum viable: 2 vCPU / 4 GB

```bash
helm install o11y ./charts/hyperdx -f charts/hyperdx/values-small.yaml
```

| Component | CPU | Memory | Disk |
|---|---:|---:|---:|
| hyperdx | 150m | 384Mi | — |
| otel-collector | 100m | 256Mi | — |
| ClickHouse | 250m | 1Gi | 10Gi |
| Keeper | 50m | 128Mi | 2Gi |
| MongoDB × 1 | 150m | 384Mi | 5Gi |
| **Total** | **700m** | **2.1 GiB** | **17 GiB** |

Fits in ~1.5 vCPU / 3 GiB allocatable with room for the operators themselves.

### What you give up

- **MongoDB drops to 1 member.** No failover. If that pod's node dies you lose dashboards,
  users, and alert rules until it returns. Telemetry is unaffected. Back it up.
- **Retention drops to 7 days** (`tablesTtl: 168h`, from 30 days). This is the single
  biggest lever on disk usage.
- **ClickHouse gets 1 GiB.** Fine for modest ingest; large or high-cardinality queries will
  be slow or fail. See the tuning note below.
- **No headroom for spikes.** A burst of telemetry can OOM the collector.

### Roughly what it handles

Very approximate, and enormously dependent on your data:

- ~50–100 GB/day ingest is **far** beyond this. Don't.
- ~1–5 GB/day of logs and traces is comfortable.
- A handful of concurrent users browsing the UI.

Treat it as a homelab, a dev environment, or a single small service — not a production
observability platform.

---

## Running even smaller

If 2 vCPU / 4 GB is still too much, stop self-hosting the data layer:

```yaml
clickhouse:
  enabled: false
  external:
    host: your-clickhouse-cloud-host
mongodb:
  enabled: false
  external:
    connectionStringSecret: mongo-atlas-conn
```

That leaves only the two stateless Deployments — about **250m CPU and 640Mi RAM**, no PVCs,
and no operators required. ClickHouse Cloud and MongoDB Atlas both have free or cheap tiers.

This is genuinely the better call on constrained hardware. ClickHouse in 1 GiB is not a
happy ClickHouse.

---

## Production

```bash
helm install o11y ./charts/hyperdx -f charts/hyperdx/values-production.yaml
```

Start at 8 vCPU / 32 GB and grow ClickHouse first. Key points:

- **ClickHouse is what you scale.** Give it as much RAM as you can; it uses memory for mark
  caches and query execution. 4–8 GiB is a reasonable floor for real workloads.
- **MongoDB stays small.** It holds config, not telemetry. 3 members at 512Mi each is
  usually enough forever.
- **Collector scales horizontally.** Add replicas rather than growing one pod; put a
  Service in front and let OTLP clients load-balance.
- **hyperdx scales horizontally** for UI concurrency, but the API is not the bottleneck —
  ClickHouse query time is.

---

## Sizing ClickHouse storage

Storage is driven almost entirely by ingest rate × retention:

```
disk ≈ daily_ingest_bytes × retention_days × compression_factor × 1.3
```

ClickHouse typically compresses observability data **8–15×**, so use `0.1` as a rough
compression factor. The `1.3` is merge headroom — ClickHouse needs free space to merge parts
and will break if you fill the disk.

| Daily ingest | 7 days | 30 days | 90 days |
|---|---:|---:|---:|
| 1 GB/day | 2 GB | 5 GB | 15 GB |
| 10 GB/day | 15 GB | 50 GB | 150 GB |
| 100 GB/day | 100 GB | 400 GB | 1.2 TB |

Set retention with `otelCollector.tablesTtl` (a Go duration, e.g. `168h` = 7 days).

**Changing `tablesTtl` after install does not retroactively alter existing tables.** The
collector's schema seed is `CREATE TABLE IF NOT EXISTS` with no version tracking, so it
won't rewrite a TTL that's already set. You have to `ALTER TABLE ... MODIFY TTL` by hand.
Pick your retention before first install.

Also make sure the PVC can actually grow — set a `storageClassName` with
`allowVolumeExpansion: true`, or you will be migrating data later.

---

## Tuning ClickHouse for small memory

Below about 2 GiB, ClickHouse needs to be told to restrain itself, or it will assume it can
use most of the machine and get OOM-killed:

```yaml
clickhouse:
  extraSettings:
    max_server_memory_usage_to_ram_ratio: 0.7
    mark_cache_size: 268435456          # 256 MiB, default is 5 GiB
    uncompressed_cache_size: 0          # disable
    max_concurrent_queries: 20
```

The default `mark_cache_size` alone is 5 GiB, which is larger than the entire node you're
trying to run on.

> **Do not set `background_pool_size` low.** It looks like an obvious small-node knob and it
> is a trap. ClickHouse refuses to start (exit 36, `BAD_ARGUMENTS`) unless
> `background_pool_size × background_merges_mutations_concurrency_ratio` is at least
> `number_of_free_entries_in_pool_to_execute_mutation`, which defaults to 20. Setting it to
> `4` yields `4 × 2 = 8` and the server dies in a crash loop with:
>
> ```
> The value of 'number_of_free_entries_in_pool_to_execute_mutation' setting (20) is greater
> than the value of 'background_pool_size'*'background_merges_mutations_concurrency_ratio' (8)
> ```
>
> It saves threads, not memory. Leave it alone.

## The ClickHouse version probe

Before starting the cluster, the operator runs a short-lived Job to detect the ClickHouse
version. Its default memory limit is 256 MiB, which **OOMs on arm64 and constrained nodes**.

The Job uses `backoffLimit: 0`, so a single failure is terminal. The cluster then sits
indefinitely reporting only:

```
Cannot probe replicas
```

with no ClickHouse pod ever created — a confusing symptom, because nothing mentions the
probe. The chart therefore sets `clickhouse.versionProbe.resources` to 512Mi/1Gi by default.

If you hit this on an existing release, raising the memory is not enough on its own — the
failed Job must also be deleted before the operator will retry:

```bash
kubectl delete job -n <ns> -l clickhouse.com/cluster=<release>-hyperdx
```

---

## The collector memory limiter

The collector image ships with an internal `memory_limiter` processor set around
**1.5 GiB**. It starts refusing data when it approaches that.

This means **`limits.memory` must exceed ~1.5 GiB**, or the container is OOM-killed by the
kernel before the limiter ever gets a chance to shed load gracefully. Being killed loses
in-flight data; the limiter applies backpressure instead.

So even in the small profile the collector keeps a 2 GiB *limit* while requesting only
256Mi. This costs nothing when idle — limits are not reserved.

If you genuinely need the limiter lower, override the whole collector config via
`otelCollector.customConfig`. That replaces the entire pipeline definition, so only do it if
you're prepared to maintain it across upgrades.

---

## Symptoms and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Pods stuck `Pending` | Requests exceed allocatable | Use `values-small.yaml`; check `kubectl describe node` |
| Collector `OOMKilled` | Limit at or below 1.5 GiB | Raise `otelCollector.resources.limits.memory` to 2Gi+ |
| ClickHouse `OOMKilled` | Caches sized for a bigger machine | Apply the tuning block above |
| Queries time out | ClickHouse starved of RAM | Give it more memory before more CPU |
| Disk full, ClickHouse read-only | No merge headroom | Expand the PVC; lower `tablesTtl` |
| Mongo CR never `Running` | 3 members won't fit | Set `mongodb.members: 1` |
| Everything slow on first install | Image pulls plus operator reconcile | Wait; MCK can take several minutes |

Check what's actually being used before guessing:

```bash
kubectl top pods -n observability
kubectl describe node | grep -A6 "Allocated resources"
```
