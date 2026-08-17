# hyperdx-helm

A Helm chart for [HyperDX](https://github.com/hyperdxio/hyperdx) — the open-source
observability platform (logs, traces, metrics, session replay) built on ClickHouse and
OpenTelemetry, now branded **ClickStack**. Stateful backends are **operator-managed**:
ClickHouse via the official ClickHouse operator, MongoDB via MongoDB Controllers for
Kubernetes (MCK).

> **Status: early but validated.** Verified end to end on a live cluster — a clean-room
> install brings up all five components, the collector creates its ClickHouse schema, and
> OTLP data sent to `:4318` is queryable from ClickHouse. Not yet run in production, and
> only single-node ClickHouse has been exercised. Treat `0.1.x` as a preview.

**In this README:** [Why this chart](#why-this-chart) ·
[Quick start](#quick-start) · [Architecture](#architecture) ·
[Configuration](#configuration) · [Sending telemetry](#sending-telemetry) ·
[Operating it](#operating-it) · [Security notes](#security-notes) ·
[Docs](#more-documentation)

## Why this chart

`hyperdxio/helm-charts` was archived in March 2026 and development moved to
[ClickStack-helm-charts](https://github.com/ClickHouse/ClickStack-helm-charts). That chart
is the official option and a good default.

This one differs in a few opinions:

- **Secrets stay out of rendered manifests.** The official chart's default path passes
  the ClickHouse password as a plain env value inside `DEFAULT_CONNECTIONS` (a Secret
  mode is opt-in); here it always comes from a Secret.
- **Generated passwords survive `helm upgrade`** instead of rotating and breaking the
  deployment or logging everyone out.
- **Operators are strictly prerequisites**, never bundled — so `helm uninstall` can't take
  out CRDs other workloads depend on.
- **Bring-your-own backends are first-class.** Point at an existing ClickHouse or MongoDB
  and the chart deploys only the stateless parts.

If you don't need any of that, use the official chart.

## Quick start

Four steps. Each has one gotcha, and each gotcha is the thing people trip on.

### 1. Install the operators (once per cluster)

- Kubernetes >= 1.27, Helm >= 3.13
- [ClickHouse operator](https://github.com/ClickHouse/clickhouse-operator) — provides
  `clickhouse.com/v1alpha1`
- [MongoDB Controllers for Kubernetes](https://github.com/mongodb/mongodb-kubernetes) —
  provides `mongodbcommunity.mongodb.com/v1`

Both ship in **one** chart — `clickstack-operators` bundles MCK alongside the ClickHouse
operator (installing `mongodb/mongodb-kubernetes` separately fails on ClusterRole
ownership conflicts):

```bash
helm repo add clickstack https://clickhouse.github.io/ClickStack-helm-charts
helm install clickstack-operators clickstack/clickstack-operators \
  --namespace clickhouse --create-namespace \
  --set-string 'mongodb-operator.operator.watchNamespace=*'
```

> **Gotcha:** `watchNamespace` is not optional if you deploy into a different namespace
> than the operators, and it cannot be changed later by `helm upgrade` (immutable
> `roleRef`). Get it right now — see the [runbook](docs/runbook.md#1-install-the-operators).

Skipping a backend? Set `clickhouse.enabled=false` or `mongodb.enabled=false`, supply
connection details, and you don't need that operator at all.

### 2. Install the chart

From the published repo (once the first release is out):

```bash
helm repo add hyperdx-helm https://rahulreddy15.github.io/hyperdx-helm
```

Or from a clone, using `./charts/hyperdx` as the chart reference:

```bash
helm install o11y ./charts/hyperdx \
  --namespace observability --create-namespace \
  --set hyperdx.publicUrl=https://hyperdx.example.com \
  --set ingress.enabled=true \
  --set ingress.host=hyperdx.example.com \
  --set clickhouse.auth.collectorPassword="$(openssl rand -base64 24)" \
  --set clickhouse.auth.appPassword="$(openssl rand -base64 24)"
```

> **Gotcha:** the two ClickHouse passwords are **required on first install** — the render
> fails without them (deliberately: Helm can't generate one random value consistently
> across the Secret *and* the ClickHouse CR, and a mismatch would brick the install).
> Everything else has a working default; the session secret and MongoDB password are
> generated on first install and preserved across upgrades. Prefer
> `clickhouse.auth.existingSecret` if you manage secrets externally — and you **must** use
> the existing-secret paths under Argo CD, where `lookup` never works
> ([runbook §4](docs/runbook.md#4-gitops--argo-cd)).

The chart defaults assume roughly a 4 vCPU / 8 GB node. For a 2 vCPU / 4 GB node add
`-f charts/hyperdx/values-small.yaml`; for production start from
`values-production.yaml`. See [sizing](docs/sizing.md).

### 3. Register the first user

> **Gotcha:** a freshly installed stack accepts **no telemetry**. The collector comes up
> healthy but does not listen on 4317/4318 at all — HyperDX only wires the OTLP receiver
> into the collector's pipelines once a team with an API key exists, and teams are created
> by registration.

Register through the UI, or headlessly:

```bash
curl -X POST http://<hyperdx>:8000/register/password \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"...","confirmPassword":"..."}'
```

Within about a minute the collector picks up its new config and 4317/4318 start listening.

### 4. Send telemetry

Grab the team API key (**Team Settings → API Keys**) and put it in an `authorization`
header. In-cluster endpoint:

```
http://o11y-hyperdx-otel-collector.observability.svc.cluster.local:4318
```

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://o11y-hyperdx-otel-collector:4318
export OTEL_EXPORTER_OTLP_HEADERS="authorization=<team-api-key>"
export OTEL_SERVICE_NAME=my-service
```

> **Gotcha:** the header is the **bare** key — `authorization: <team-api-key>`, **not**
> `Bearer <key>`. The collector's bearer-token extension is configured with `scheme: ''`,
> so prefixing it fails with 401. This trips people up constantly.

For senders outside the cluster, enable `otlpIngress`. OTLP **HTTP** works through a
standard Ingress; **gRPC** usually needs controller-specific annotations or a
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
logins, but the telemetry survives. (A `KeeperCluster` is deployed even for single-node
ClickHouse — the official operator requires `keeperClusterRef` unconditionally, and uses
Keeper to replicate the `default` database's DDL.)

**ClickHouse is single-node by design here, and the chart refuses `replicas`/`shards`
above 1.** Verified on a live cluster: the operator replicates schema across replicas,
but the collector's `MergeTree` tables do not replicate *data* — replicas silently
diverge behind one Service while every pod reports Ready. Scale ClickHouse vertically,
or point the chart at your own replicated ClickHouse (`clickhouse.enabled=false`).

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
receivers exist — which is why telemetry cannot flow before a team exists (step 3 above).

**② Telemetry never passes through the app.** The collector writes straight to ClickHouse
over the native protocol on 9000. The app only *reads*, over HTTP on 8123, as a different
user with different grants. A slow UI never slows ingestion, and an app outage doesn't
stop data landing.

## Configuration

Every value is documented in [`values.yaml`](charts/hyperdx/values.yaml) — that file is
the reference. The highlights:

| Concern | Values | Notes |
|---|---|---|
| Sizing | `-f values-small.yaml` / defaults / `-f values-production.yaml` | 2/4/8+ vCPU nodes — [sizing](docs/sizing.md) |
| Credentials | `clickhouse.auth.*`, `mongodb.password`, `auth.sessionSecret` | CH passwords required on install; the rest generated and retained |
| Externally managed secrets | `*.existingSecret` | Required under Argo CD / GitOps |
| Bring your own ClickHouse | `clickhouse.enabled=false` + `clickhouse.external.*` | No operator needed |
| Bring your own MongoDB | `mongodb.enabled=false` + `mongodb.external.*` | URI or Secret reference |
| Retention | `otelCollector.tablesTtl` | Applied at table creation only — decide **before** first install |
| UI / OTLP exposure | `ingress.*`, `otlpIngress.*` | gRPC ingress needs controller-specific setup |
| Custom collector pipelines | `otelCollector.customConfig` | Replaces the entire pipeline definition; you own it across upgrades |

### The two credentials people confuse

| | Who uses it | Where it lives |
|---|---|---|
| **Email + password** | Humans logging into the UI | MongoDB `users` |
| **Team API key** | Applications sending telemetry | MongoDB `teams.apiKey` |

Open-source HyperDX supports **local email/password only** — SSO/OAuth/SAML are cloud and
enterprise features. (The `config.standalone.oidc.yaml` file in the upstream repo is a
*collector-side* authenticator, not UI OIDC. Easy to misread.) The first registration
bootstraps the team; subsequent registrations are rejected. There is no
`DISABLE_REGISTRATION` switch, so if the UI is public, block `/register/password` at the
ingress once you've registered. Additional users join via team invites
(`/join-team?token=...`).

Two related traps:

- **`HYPERDX_API_KEY` (`auth.apiKey`) is not the ingestion key.** It configures HyperDX's
  own self-instrumentation. Putting it in your `authorization` header will not work.
- **Ingestion auth can be turned off** by clearing `collectorAuthenticationEnforced` on
  the team document — only sensible when NetworkPolicy already restricts who can reach
  the collector. The flag is read from the *first* team, not per-receiver.

## Sending telemetry

What the collector accepts out of the box:

| Format | Port | Path | Auth |
|---|---:|---|---|
| OTLP gRPC | 4317 | — | Team API key |
| OTLP HTTP | 4318 | `/v1/logs`, `/v1/traces`, `/v1/metrics` | Team API key |
| Fluent Forward | 24225 | — | **None** |
| Prometheus | — | scrape-only | n/a |
| Datadog | 8126 | Datadog intake | opt-in, see below |

- **Fluent Forward is not protected by the team API key** (upstream has a TODO
  acknowledging it). Anything that can reach 24225 can write. Keep it ClusterIP and
  restrict it with NetworkPolicy.
- **Prometheus is scrape-only** — the collector scrapes its own metrics (8888) and
  ClickHouse (9363). There is no remote-write endpoint; `ENABLE_PROMQL=true` adds a query
  path, not ingestion.
- **Session replay** (`@hyperdx/browser`) uses the same OTLP endpoint and team key;
  replay events are OTel logs tagged `rr-web.event`, stored in `hyperdx_sessions`.
- **Datadog** (`otelCollector.enableDatadogReceiver`) is off by default and
  **unauthenticated when no team key exists**. Don't expose it without a deliberate
  decision.

The image compiles in more receivers than it enables (`filelog`, `hostmetrics`,
`dockerstats`, `k8scluster`, `kubeletstats`, …). Turning them on means
`otelCollector.customConfig`, which replaces the whole app-generated pipeline — you then
own it across upgrades.

## Operating it

### Pod readiness lies here — alert on data, not on pods

Two probes on this stack pass while the thing they appear to vouch for is broken:

- The collector's readiness probe checks port 13133, which answers happily **with no
  pipeline running** — observed `1/1 Ready` for ten minutes while every send was refused.
- The app's `/health` returns 200 **with MongoDB entirely unreachable**.

Alert on rows arriving in ClickHouse. This is not hypothetical: in load testing, an
undersized collector refused 64% of traffic while Kubernetes reported it `Running`,
`Ready`, zero restarts, the whole time.

### What load testing showed

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
[docs/load-testing.md](docs/load-testing.md).

### Upgrading

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

### Backups

MCK Community has no backup integration — a 3-member replica set is availability, not
backup. Back up MongoDB (dashboards, users, alert rules) with Velero, CSI snapshots, or a
scheduled `mongodump`. ClickHouse is usually reconstructible from re-ingested telemetry;
if you can't accept its loss, snapshot the PVC.

## Security notes

- ClickHouse user passwords render into the `ClickHouseCluster` CR — the official
  operator has no `secretKeyRef` for users (Altinity's does). Restrict RBAC on that
  resource.
- Fluent Forward (24225) and the optional Datadog receiver are the unauthenticated
  surfaces. Keep them ClusterIP + NetworkPolicy'd.
- `hyperdx.usageStatsEnabled` defaults to `false` here.
- Upstream images are **not** cosign-signed, and the collector image ships without
  SBOM/provenance attestations. Sign on ingest if that matters to you.

## More documentation

| Doc | What's in it |
|---|---|
| [docs/runbook.md](docs/runbook.md) | Operator install, first run, credentials, Argo CD, troubleshooting, uninstall |
| [docs/sizing.md](docs/sizing.md) | Profiles, small-node tuning, storage math, the version-probe and memory-limiter traps |
| [docs/load-testing.md](docs/load-testing.md) | Methodology and reproduction for the numbers above |
| [AGENTS.md](AGENTS.md) | Design decisions, upstream tracking, and the accumulated gotchas — read before contributing |
| [charts/hyperdx/README.md](charts/hyperdx/README.md) | Chart-level values reference |

## Contributing

```bash
helm lint charts/hyperdx
helm template t charts/hyperdx \
  --set clickhouse.auth.collectorPassword=a --set clickhouse.auth.appPassword=b > /dev/null
```

A bare `helm template` with no ClickHouse credentials is **expected to fail** — that's the
first-install credential guard, not a bug. Every values file under `charts/hyperdx/ci/`
must render cleanly.

CI also runs a real-cluster test on kind (`.github/workflows/e2e.yaml`): fresh install →
headless registration → OTLP send → row asserted in ClickHouse, plus a base-branch → PR
upgrade asserting generated credentials survive. Run it against any local cluster with
`.github/scripts/e2e.sh`. See [AGENTS.md](AGENTS.md) before making changes.

## License

[Apache 2.0](LICENSE). HyperDX itself is licensed separately by its authors.
