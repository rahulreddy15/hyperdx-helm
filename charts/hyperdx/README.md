# HyperDX Helm chart

Deploys HyperDX/ClickStack and its collector, plus Custom Resources for operator-managed ClickHouse and MongoDB.

## Prerequisites

- Kubernetes 1.27+
- Official ClickHouse operator (`clickhouse.com/v1alpha1`)
- MongoDB Controllers for Kubernetes (`mongodbcommunity.mongodb.com/v1`)

Operators must be installed separately; this chart never owns or removes them.

```sh
helm install hyperdx ./charts/hyperdx --set hyperdx.publicUrl=https://hyperdx.example.com \
  --set clickhouse.auth.collectorPassword="$(openssl rand -base64 24)" \
  --set clickhouse.auth.appPassword="$(openssl rand -base64 24)"
```

## Sizing

| Profile | Suggested node | Values file |
|---|---:|---|
| Small | 2 vCPU / 4 GB | `values-small.yaml` |
| Default | 4 vCPU / 8 GB | `values.yaml` |
| Production | 8+ vCPU / 32+ GB | `values-production.yaml` |

See [`docs/sizing.md`](../../docs/sizing.md) for resource totals, tradeoffs, and tuning guidance.

## First run

OTLP ingestion remains disabled until a user registers. HyperDX only adds the `otlp/hyperdx` receiver to collector pipelines after a team with an API key exists. Once a team exists, `collectorAuthenticationEnforced` is true and OTLP senders must provide that team API key in the `authorization` header.

## Main values

| Value | Default | Description |
|---|---:|---|
| `hyperdx.publicUrl` | `""` | Public UI URL |
| `hyperdx.replicas` | `1` | HyperDX replicas |
| `hyperdx.defaultSources` | four built-in sources | JSON used to bootstrap log, trace, metric, and session UI sources; database names follow `otelCollector.clickhouseDatabase` |
| `otelCollector.enabled` | `true` | Deploy collector |
| `otelCollector.clickhousePrometheusEndpoint` | `""` | ClickHouse Prometheus target; empty derives `<clickhouse-host>:9363` (no scheme) |
| `clickhouse.enabled` | `true` | Create ClickHouse/Keeper CRs |
| `clickhouse.auth.collectorPassword` | required initially | Collector password; alternatively configure `clickhouse.auth.existingSecret` |
| `clickhouse.auth.appPassword` | required initially | Application password; alternatively configure `clickhouse.auth.existingSecret` |
| `clickhouse.externalSecret.name` | `""` | Externally-managed Secret for the operator's internal cluster credentials (not user passwords); `policy` Observe or Manage |
| `mongodb.enabled` | `true` | Create MongoDBCommunity CR |
| `mongodb.rbac.create` | `true` | Create MCK database-pod service accounts and namespace RBAC; disable when centrally provisioned |
| `auth.sessionSecret` | generated | Session encryption secret |
| `ingress.enabled` | `false` | Expose UI through ingress |
| `otlpIngress.enabled` | `false` | Expose OTLP/HTTP ingress |
| `alerting.externalCronJob.enabled` | `false` | Run alert checks externally |
| `bootstrap.register.enabled` | `false` | Post-install hook Job registers the first user headlessly (requires `email` + `existingSecret` with key `password`) |
| `networkPolicy.appIngressFrom` | `[]` | Peers allowed to reach UI/API; empty = any. OpAMP always restricted to the release's collector |
| `networkPolicy.telemetryIngressFrom` | `[]` | Peers allowed to send OTLP/Datadog; empty = any; the app itself is always admitted |
| `networkPolicy.fluentdIngressFrom` | `[]` | Peers allowed on unauthenticated fluentd 24225; **empty denies the port** |

ClickHouse passwords must be supplied on first install because Helm cannot safely share a random value across independently rendered templates. Existing generated chart Secrets remain reusable during upgrades. External ClickHouse mode likewise requires explicit external users/passwords or `clickhouse.auth.existingSecret`; credentials are never fabricated.

See the fully commented `values.yaml` for all settings. The official ClickHouse operator cannot reference Secrets for user passwords, so passwords appear in the ClickHouse CR; restrict CR read access. Deployment and PDB selectors gained component labels and are immutable; uninstall/reinstall releases created by an older chart.
