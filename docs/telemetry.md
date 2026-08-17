# Sending telemetry

The reference for getting data in: formats, ports, auth, and the credential model.
First-time setup (registration, port-forwards) is in the
[README quick start](../README.md#quick-start); restricting who can reach these ports
is in the [runbook](runbook.md).

## What the collector accepts

| Format | Port | Path | Auth |
|---|---:|---|---|
| OTLP gRPC | 4317 | — | Team API key |
| OTLP HTTP | 4318 | `/v1/logs`, `/v1/traces`, `/v1/metrics` | Team API key |
| Fluent Forward | 24225 | — | **None** |
| Prometheus | — | scrape-only | n/a |
| Datadog | 8126 | Datadog intake | opt-in, see below |

- **Fluent Forward is not protected by the team API key** (upstream has a TODO
  acknowledging it). Anything that can reach 24225 can write. Keep it ClusterIP and
  restrict it with NetworkPolicy — with `networkPolicy.enabled=true` the port is denied
  by default until you list peers in `networkPolicy.fluentdIngressFrom`.
- **Prometheus is scrape-only** — the collector scrapes its own metrics (8888) and
  ClickHouse (9363). There is no remote-write endpoint; `ENABLE_PROMQL=true` adds a query
  path, not ingestion.
- **Session replay** (`@hyperdx/browser`) uses the same OTLP endpoint and team key;
  replay events are OTel logs tagged `rr-web.event`, stored in `hyperdx_sessions`.
- **Datadog** (`otelCollector.enableDatadogReceiver`) is off by default and
  **unauthenticated when no team key exists**. Don't expose it without a deliberate
  decision.

## The auth header

Put the team API key in an `authorization` header — **bare**, with no `Bearer` prefix.
The collector's bearer-token extension is configured with `scheme: ''`, so
`Bearer <key>` fails with 401. This trips people up constantly.

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://o11y-hyperdx-otel-collector:4318
export OTEL_EXPORTER_OTLP_HEADERS="authorization=<team-api-key>"
export OTEL_SERVICE_NAME=my-service
```

For senders outside the cluster, enable `otlpIngress`. OTLP **HTTP** works through a
standard Ingress; **gRPC** usually needs controller-specific annotations or a
LoadBalancer Service.

## The two credentials people confuse

| | Who uses it | Where it lives |
|---|---|---|
| **Email + password** | Humans logging into the UI | MongoDB `users` |
| **Team API key** | Applications sending telemetry | MongoDB `teams.apiKey` |

Open-source HyperDX supports **local email/password only** — SSO/OAuth/SAML are cloud and
enterprise features. (The `config.standalone.oidc.yaml` file in the upstream repo is a
*collector-side* authenticator, not UI OIDC. Easy to misread.) The first registration
bootstraps the team; subsequent registrations are rejected. There is no
`DISABLE_REGISTRATION` switch, so if the UI is public, block `/register/password` at the
ingress once you've registered — the [runbook](runbook.md#lock-down-registration) has a
copy-paste snippet. Additional users join via team invites (`/join-team?token=...`).

Two related traps:

- **`HYPERDX_API_KEY` (`auth.apiKey`) is not the ingestion key.** It configures HyperDX's
  own self-instrumentation. Putting it in your `authorization` header will not work.
- **Ingestion auth can be turned off** by clearing `collectorAuthenticationEnforced` on
  the team document — only sensible when NetworkPolicy already restricts who can reach
  the collector. The flag is read from the *first* team, not per-receiver.

## Enabling more receivers

The image compiles in more receivers than it enables (`filelog`, `hostmetrics`,
`dockerstats`, `k8scluster`, `kubeletstats`, …). Turning them on means
`otelCollector.customConfig`, which replaces the whole app-generated pipeline — you then
own it across upgrades.
