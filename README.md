# hyperdx-helm

A Helm chart for [HyperDX](https://github.com/hyperdxio/hyperdx) — the open-source
observability platform (logs, traces, metrics, session replay) built on ClickHouse and
OpenTelemetry, now branded **ClickStack**. Stateful backends are **operator-managed**:
ClickHouse via the official ClickHouse operator, MongoDB via MongoDB Controllers for
Kubernetes (MCK).

> **Verified end to end.** Clean-room install, headless registration, OTLP ingest, and
> upgrade credential retention are exercised on real clusters — by the kind-based e2e
> suite in CI and by repeated live runs of exactly the quickstart below, most recently a
> from-scratch minikube bring-up. Data sent to `:4318` lands in ClickHouse and is
> queryable in the UI.

**In this README:** [Why this chart](#why-this-chart) ·
[Quick start](#quick-start) · [Architecture](#architecture) ·
[Configuration](#configuration) · [Sending telemetry](#sending-telemetry) ·
[Operating it](#operating-it) · [Docs](#more-documentation)

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

- Kubernetes >= 1.28 for the default operator-managed path (the ClickHouse operator
  chart enforces it); >= 1.27 suffices when both backends are external
- Helm >= 3.13
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
connection details, and you don't need that operator at all. With an external MongoDB
you can also skip the bundle and install just the ClickHouse operator standalone:

```bash
helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm \
  --namespace clickhouse-operator-system --create-namespace
```

### 2. Install the chart

```bash
helm repo add hyperdx-helm https://rahulreddy15.github.io/hyperdx-helm
helm install o11y hyperdx-helm/hyperdx \
  --namespace observability --create-namespace \
  --set hyperdx.publicUrl=https://hyperdx.example.com \
  --set ingress.enabled=true \
  --set ingress.host=hyperdx.example.com \
  --set clickhouse.auth.collectorPassword="$(openssl rand -base64 24)" \
  --set clickhouse.auth.appPassword="$(openssl rand -base64 24)"
```

(From a clone, use `./charts/hyperdx` as the chart reference instead of
`hyperdx-helm/hyperdx`.)

**Running locally (minikube, kind, Docker Desktop)?** Skip the ingress and point
`publicUrl` at the port-forward you'll use:

```bash
helm install o11y ./charts/hyperdx \
  --namespace observability --create-namespace \
  --set hyperdx.publicUrl=http://localhost:8080 \
  --set clickhouse.auth.collectorPassword="$(openssl rand -base64 24)" \
  --set clickhouse.auth.appPassword="$(openssl rand -base64 24)"
```

> **Gotcha:** `publicUrl` is where the app sends the browser back after every login
> attempt (`FRONTEND_URL`). Point it at a host your browser can't reach — or leave it
> empty locally, which defaults to the in-cluster Service URL — and login bounces to the
> wrong host with `?err=authFail`. For port-forward access it must be
> `http://localhost:8080`. Already installed with the wrong value? Fix without losing
> anything: `helm upgrade o11y ./charts/hyperdx -n observability --reuse-values
> --set ingress.enabled=false --set hyperdx.publicUrl=http://localhost:8080`.

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

Watch it come up with `kubectl get pods -n observability -w`. Five pods appear: Keeper,
ClickHouse, and MongoDB (created by the operators a minute or so after install), then
the app and collector. **MongoDB is normally the last one Ready** — MCK's automation
agent configures the replica set inside the pod before `mongod` starts serving, which
adds a few minutes. It's not stuck.

### 3. Register the first user

> **Gotcha:** a freshly installed stack accepts **no telemetry**. The collector comes up
> healthy but does not listen on 4317/4318 at all — HyperDX only wires the OTLP receiver
> into the collector's pipelines once a team with an API key exists, and teams are created
> by registration.

Running locally, port-forward the app first, then register in the browser at
http://localhost:8080 (signup form) — or headlessly against `localhost:8000`:

```bash
kubectl port-forward svc/o11y-hyperdx -n observability 8080:8080 8000:8000
```

Register through the UI, or headlessly:

```bash
curl -X POST http://<hyperdx>:8000/register/password \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"...","confirmPassword":"..."}'
```

…or fully hands-off: set `bootstrap.register.enabled=true` with an email and a
password Secret, and a post-install hook Job performs the registration for you —
re-runs treat "team already exists" as success, so it is GitOps-safe.

Within about a minute the collector picks up its new config and 4317/4318 start listening.

### 4. Send telemetry

Grab the team API key (**Team Settings → API Keys**) and put it in an `authorization`
header. In-cluster endpoint:

```
http://o11y-hyperdx-otel-collector.observability.svc.cluster.local:4318
```

Locally, port-forward the collector and send to `http://localhost:4318`:

```bash
kubectl port-forward svc/o11y-hyperdx-otel-collector -n observability 4318:4318
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

Which credential goes where — UI login vs team API key vs `HYPERDX_API_KEY` — is the
single most confusing part of HyperDX. The short version: humans log in with email +
password, apps send telemetry with the team API key, and `HYPERDX_API_KEY` is neither.
The full model, including registration lockdown and the auth-off escape hatch, is in
[docs/telemetry.md](docs/telemetry.md#the-two-credentials-people-confuse).

## Sending telemetry

OTLP gRPC on **4317** and OTLP HTTP on **4318**, authenticated by the team API key sent
as a **bare** `authorization` header (`Bearer` fails with 401). Also accepted: Fluent
Forward on 24225 (**no auth** — keep it ClusterIP and NetworkPolicy-restricted),
Prometheus scrape targets, session replay over OTLP, and an opt-in Datadog receiver on
8126. Ports, paths, caveats, and how to enable more receivers:
[docs/telemetry.md](docs/telemetry.md).

## Operating it

Four facts carry most of the operational weight — the reasoning behind each is in
[docs/operations.md](docs/operations.md):

- **Alert on rows arriving in ClickHouse, not on pod health.** Both the collector's and
  the app's probes pass while the thing they vouch for is broken; in load testing an
  undersized collector refused 64% of traffic while `Running`, `Ready`, zero restarts.
- **Load-tested with zero loss** (28.6 M records over 180 s on the small profile), but
  margins were thin — and never set the collector memory limit at or below ~1.5 Gi,
  where its internal `memory_limiter` sits.
- **The upgrade gate is a schema diff.** The collector never migrates existing tables,
  so diff the upstream schema paths before bumping `appVersion`; the `upstream-check`
  workflow does this weekly and opens an issue.
- **Back up MongoDB** (dashboards, users, alert rules) — MCK Community has no backup
  integration. ClickHouse is usually reconstructible from re-ingested telemetry.

Security posture — unauthenticated ports, NetworkPolicy defaults, image signing — is
covered in [docs/operations.md](docs/operations.md#security-notes).

## More documentation

| Doc | What's in it |
|---|---|
| [docs/runbook.md](docs/runbook.md) | Operator install, first run, credentials, Argo CD, troubleshooting, uninstall |
| [docs/telemetry.md](docs/telemetry.md) | Formats, ports, auth headers, and the credential model |
| [docs/operations.md](docs/operations.md) | Alerting, load-test findings, upgrades, backups, security notes |
| [docs/sizing.md](docs/sizing.md) | Profiles, small-node tuning, storage math, the version-probe and memory-limiter traps |
| [docs/load-testing.md](docs/load-testing.md) | Methodology and reproduction for the load-test numbers |
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
