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

### How the pieces talk

```
                      ┌──────────────────────────────────────┐
   browser ──8080──▶  │             hyperdx                  │
   (UI + login)       │  Next.js UI :8080                    │
                      │  REST API   :8000                    │
                      │  OpAMP      :4320                    │
                      └───┬───────────────┬──────────────┬───┘
                          │               │              ▲
              queries via │        reads/ │              │ ① collector polls
              HTTP :8123  │        writes │              │   for its config
                          ▼               ▼              │
                   ┌────────────┐   ┌──────────┐         │
                   │ ClickHouse │   │ MongoDB  │         │
                   │ 8123 HTTP  │   │  :27017  │         │
                   │ 9000 native│   └──────────┘         │
                   │ 9363 prom  │   users, teams,        │
                   └─────▲──────┘   API keys, dashboards,│
                         │          sources, alerts      │
        ② writes via     │                               │
        native :9000     │                               │
                   ┌─────┴────────────────────────────┐  │
   your apps ──▶   │        otel-collector            │──┘
                   │  OTLP gRPC   :4317               │
                   │  OTLP HTTP   :4318               │
                   │  FluentFwd   :24225              │
                   │  health      :13133              │
                   │  self-metrics:8888               │
                   └──────────────────────────────────┘
```

Two things about this are worth internalising:

**① The collector pulls its own config.** It opens an OpAMP connection *outbound* to the
app on 4320 and receives its entire pipeline definition in reply. The app decides which
receivers exist. This is why telemetry cannot flow before a team exists — see below.

**② Telemetry never passes through the app.** The collector writes straight to ClickHouse
over the native protocol on 9000. The app only *reads*, over HTTP on 8123, as a different
user with different grants. So a slow UI never slows ingestion, and an app outage doesn't
stop data landing.

## Access and authentication

There are two completely separate credentials, and confusing them is the most common
mistake.

| | Who uses it | Where it lives |
|---|---|---|
| **Email + password** | Humans logging into the UI | MongoDB `users` |
| **Team API key** | Applications sending telemetry | MongoDB `teams.apiKey` |

### Logging in

Open-source HyperDX supports **local email/password only**. SSO/OAuth and SAML are cloud
and enterprise features — there is no self-hosted OIDC login for the UI.

> The `config.standalone.oidc.yaml` and `config.standalone.auth.yaml` files in the upstream
> repo are **collector-side** authenticators for standalone deployments. They do not add
> OIDC login to the UI. Easy to misread.

The first registration bootstraps the team; subsequent registrations are rejected. There is
no `DISABLE_REGISTRATION` switch, so if the UI is public, block `/register/password` at the
ingress once you've created your account. Additional users come in through team invites
(`/join-team?token=...`).

### Sending telemetry

Grab the key from **Team Settings → API Keys**, then send it as a **bare** `authorization`
header:

```
authorization: <team-api-key>
```

**Not** `Bearer <key>`. The collector's bearer-token extension is configured with
`scheme: ''`, so prefixing it fails. This trips people up constantly.

For an OTel SDK:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://hyperdx-otel-collector:4318
export OTEL_EXPORTER_OTLP_HEADERS="authorization=<team-api-key>"
export OTEL_SERVICE_NAME=my-service
```

Forwarding from an existing collector:

```yaml
exporters:
  otlphttp/hyperdx:
    endpoint: http://hyperdx-otel-collector:4318
    headers:
      authorization: ${env:HYPERDX_TEAM_API_KEY}
    compression: gzip
```

### `HYPERDX_API_KEY` is not the ingestion key

The chart's `auth.apiKey` / `HYPERDX_API_KEY` env var is for HyperDX's **own** self-
instrumentation. It is a different thing from the per-team `apiKey` in MongoDB. Putting it
in your `authorization` header will not work unless your deployment deliberately sets both
to the same value.

### Turning ingestion auth off

Registration sets `collectorAuthenticationEnforced: true` on the team, which is what makes
the collector demand a key. It can be disabled on the team document if the collector is
already protected by network policy and only trusted in-cluster senders reach it. Note the
setting is read from the *first* team, not per-receiver.

## Telemetry formats accepted by default

| Format | Port | Path | Auth |
|---|---:|---|---|
| OTLP gRPC | 4317 | — | Team API key |
| OTLP HTTP | 4318 | `/v1/logs`, `/v1/traces`, `/v1/metrics` | Team API key |
| Fluent Forward | 24225 | — | **None** |
| Prometheus | — | scrape-only | n/a |
| Datadog | 8126 | Datadog intake | opt-in, see below |

**Fluent Forward is not protected by the team API key.** Upstream has a TODO acknowledging
this. Fluentd, Fluent Bit, and Docker's fluentd log driver can all write to 24225 with no
credential, so keep that port on a ClusterIP and covered by NetworkPolicy.

**Prometheus is scrape-only.** The collector scrapes its own metrics on 8888 and ClickHouse
on 9363. There is no remote-write ingestion endpoint. `ENABLE_PROMQL=true` adds a
PromQL-compatible query path — it does not turn this into a remote-write receiver.

**Browser / session replay** uses `@hyperdx/browser` over the same OTLP endpoint and the
same team key. Replay events are OTel logs tagged `rr-web.event`, routed to the
`hyperdx_sessions` table.

**Datadog** (`otelCollector.enableDatadogReceiver`) is off by default. Current upstream
authenticates it with `DD-API-KEY` when collector auth is enforced, but it is
**unauthenticated** when no team key exists. Don't expose it without a deliberate decision.

### Compiled vs enabled

The image ships more receivers than it turns on: `otlp`, `fluentforward`, `prometheus`,
`datadog`, `filelog`, `hostmetrics`, `dockerstats`, `k8scluster`, `kubeletstats`, `nop`.
Only OTLP, Fluent Forward, Prometheus and (optionally) Datadog are enabled by the
app-generated config. The rest need `otelCollector.customConfig`, which replaces the whole
pipeline definition — you then own it across upgrades.


## Load testing

Measured on the **small profile** (`values-small.yaml`, which targets 2 vCPU / 4 GB), on
minikube with 6 vCPU / 7 GB allocated. Synthetic OTLP log records, ~300 bytes each, sent
over HTTP with 6 concurrent senders.

### Test 1 — default limits, 3 minutes sustained

| | |
|---|---|
| Duration | 180s |
| Accepted | 57,325 requests |
| Rejected | 3,310 × HTTP 503 |
| Records sent | 28,662,500 |
| **Records in ClickHouse** | **28,662,500 (100%)** |
| Restarts / OOMKills | 0 / 0 |

Every record the collector accepted was persisted. The 503s are the `memory_limiter`
applying backpressure at the door — which is the behaviour you want. It refused work it
couldn't complete instead of accepting and silently dropping.

### Peak usage vs. what the profile requests

This is the actionable part:

| Component | CPU request | CPU peak | Mem request | Mem peak | Mem limit |
|---|---:|---:|---:|---:|---:|
| ClickHouse | 250m | **1108m** (4.4×) | 1Gi | **2033Mi** (2×) | 2Gi |
| collector | 100m | **1119m** (11×) | 256Mi | ~1679Mi (6.5×) | 2Gi |
| hyperdx | 150m | 2m | 384Mi | 399Mi | 1Gi |
| MongoDB | 150m | 20m | 384Mi | 259Mi | 1Gi |

Two things fall out of this:

**Requests are wildly below real peak usage.** Kubernetes schedules on requests, so a node
packed by these numbers will be badly oversubscribed under load. That is deliberate — it's
what lets the profile fit a small node at idle — but you should know it's a bet on
burstiness, not headroom.

**ClickHouse peaked at 2033Mi against a 2048Mi limit.** That is 15Mi of margin. On the small
profile, sustained heavy ingest sits right on the edge of an OOMKill. If you plan to push
real volume, raise the ClickHouse limit before anything else.

**Peak CPU exceeded the profile's own target.** ClickHouse and the collector together drew
~2.2 vCPU, more than the 2 vCPU the profile is named for. The test host had spare cores, so
this was never throttled. On an actual 2-core node it would have been.

### Test 2 — collector starved below its memory limiter

Same load, collector limit lowered to 512Mi (its internal `memory_limiter` sits near
1.5 GiB):

| | |
|---|---|
| Accepted | 17,054 requests |
| **Failed** | **30,644 (64%)** — 30,572 connection refused |
| Collector memory | 130Mi → 355Mi → 13Mi |
| Pod status throughout | `1/1 Running`, **restarts = 0** |

The failure mode is worse than a crash. Kubernetes reported the pod healthy the entire
time, restart count never moved, and yet nearly two thirds of telemetry was refused at the
socket. Memory collapsing to 13Mi indicates the collector process died and was restarted
*inside* the container by its supervisor, so the kubelet never saw it.

We did not fully confirm the internal mechanism — no crash appeared in the supervisor log —
so treat the cause as unconfirmed. The symptom is reproducible and unambiguous.

**Keep `otelCollector.resources.limits.memory` above 2Gi even on small nodes.** Limits
aren't reserved, so a high limit costs nothing when idle.

### Caveats — read before quoting these numbers

- **Synthetic data compresses unusually well.** Repeated padding and 50 distinct host values
  are far friendlier to ClickHouse than real telemetry. Expect lower real-world throughput.
- **The host had 6 cores.** CPU was never the binding constraint, which will not be true on
  the 2-core node this profile is named for.
- Log records only. Traces and metrics have different write patterns.
- 3 minutes is long enough to expose backpressure, not long enough to expose merge
  pressure, disk growth, or TTL behaviour.

The honest summary: **the small profile absorbed ~159k records/sec with zero data loss**,
but it did so by bursting to roughly 4× its CPU request and sitting 15Mi under its
ClickHouse memory limit. It is a valid dev/homelab profile, not a production one.

### Reproducing

The generator is a small Python script posting OTLP/HTTP with N concurrent workers for a
fixed duration, run as a pod in-cluster:

```bash
kubectl run loadgen --rm -i --restart=Never -n <ns> --image=python:3.12-alpine \
  --overrides='{"spec":{"containers":[{"name":"loadgen","image":"python:3.12-alpine",
  "command":["python","/s/load.py"],"env":[
    {"name":"APIKEY","value":"<team-api-key>"},
    {"name":"BATCH","value":"500"},{"name":"DUR","value":"180"},{"name":"CONC","value":"6"}],
  "volumeMounts":[{"name":"s","mountPath":"/s"}]}],
  "volumes":[{"name":"s","configMap":{"name":"loadgen"}}]}}'
```

Sample resource usage in parallel with `kubectl top pods`, and always compare records sent
against `SELECT count() FROM default.otel_logs` — accepting a request is not the same as
persisting it.



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

#### External MongoDB

Verified end to end: with `mongodb.enabled=false` the chart creates no `MongoDBCommunity`
CR and none of the MCK ServiceAccount/Role/RoleBinding, so **you do not need the MongoDB
operator at all** on that path. `mongodb.password` is correctly not required. Dropping the
in-cluster MongoDB also frees ~384Mi of requests.

```bash
--set mongodb.enabled=false \
--set mongodb.external.uri='mongodb://user:pass@host:27017/hyperdx?authSource=hyperdx'
```

**Get `authSource` right.** It must name the database the user was *created in*, not the
database you connect to. If you created the user inside `hyperdx`:

```
?authSource=hyperdx     ✅
?authSource=admin       ❌ authentication failed
```

Create it in `admin` instead and the reverse applies. This is the single most likely reason
a correct-looking URI fails.

Prefer `mongodb.external.connectionStringSecret` over `uri` in production so the password
stays out of the rendered Deployment.

> **The app's `/health` returns 200 even when MongoDB is completely unreachable.** During
> testing the pod sat `1/1 Ready` while every request failed with
> `MongoServerError: AuthenticationFailed`. Do not treat pod readiness as proof the
> database is connected — check the app logs.


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
