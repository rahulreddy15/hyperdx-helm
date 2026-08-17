# AGENTS.md

Template-level guidance for AI agents and humans editing `charts/hyperdx/`. Read the
repository-root `AGENTS.md` for architecture, decisions, and upstream tracking; this file
covers rendering mechanics and invariants.

## Template inventory

| File | Emits | Gate |
|---|---|---|
| `templates/_helpers.tpl` | Named template helpers; no manifest | None |
| `templates/NOTES.txt` | Post-install operator warnings, access instructions, and configuration warnings | Individual messages use capability/value checks (`NOTES.txt:1-19`) |
| `templates/clickhouse-cluster.yaml` | `ClickHouseCluster` | `clickhouse.enabled` (`clickhouse-cluster.yaml:1`) |
| `templates/clickhouse-keeper.yaml` | `KeeperCluster` | `clickhouse.enabled && clickhouse.keeper.enabled` (`clickhouse-keeper.yaml:1`) |
| `templates/configmap.yaml` | HyperDX `ConfigMap` containing `HYPERDX_LOG_LEVEL` and `DEFAULT_SOURCES` | None |
| `templates/cronjob-alerts.yaml` | Alert-checking `CronJob` | `alerting.externalCronJob.enabled` (`cronjob-alerts.yaml:1`) |
| `templates/hyperdx-deployment.yaml` | HyperDX app `Deployment` | None |
| `templates/hyperdx-service.yaml` | HyperDX app/API/OpAMP `Service` | None |
| `templates/ingress-otlp.yaml` | OTLP/HTTP `Ingress` | `otlpIngress.enabled` (`ingress-otlp.yaml:1`) |
| `templates/ingress.yaml` | HyperDX UI `Ingress` | `ingress.enabled` (`ingress.yaml:1`) |
| `templates/mongodb-rbac.yaml` | Two `ServiceAccount`s, one `Role`, and one `RoleBinding` for MCK | `mongodb.enabled && mongodb.rbac.create` (`mongodb-rbac.yaml:1`) |
| `templates/mongodb.yaml` | `MongoDBCommunity` | `mongodb.enabled` (`mongodb.yaml:1`) |
| `templates/networkpolicy.yaml` | HyperDX `NetworkPolicy`; optionally a collector `NetworkPolicy` | Outer `networkPolicy.enabled`; collector policy also requires `otelCollector.enabled` (`networkpolicy.yaml:1,18`) |
| `templates/otel-collector-configmap.yaml` | Collector custom-config `ConfigMap` | `otelCollector.enabled && otelCollector.customConfig` (`otel-collector-configmap.yaml:1`) |
| `templates/otel-collector-deployment.yaml` | Collector `Deployment` | `otelCollector.enabled` (`otel-collector-deployment.yaml:1`) |
| `templates/otel-collector-service.yaml` | Collector OTLP/health/metrics/fluentd `Service` | `otelCollector.enabled` (`otel-collector-service.yaml:1`) |
| `templates/poddisruptionbudget.yaml` | HyperDX app `PodDisruptionBudget` | `podDisruptionBudget.enabled` (`poddisruptionbudget.yaml:1`) |
| `templates/secret.yaml` | Retained chart `Secret`: session, ClickHouse and MongoDB credentials, default connection JSON, API key | None |
| `templates/serviceaccount.yaml` | Workload `ServiceAccount` | `serviceAccount.create` (`serviceaccount.yaml:1`) |
| `templates/tests/test-connection.yaml` | `helm test` Pod that calls the API health endpoint | None; executed as a test hook (`tests/test-connection.yaml:6-8`) |

## Helper reference

All helpers are in `templates/_helpers.tpl`.

| Helper | Returns | Used by |
|---|---|---|
| `hyperdx.name` | Chart name or `nameOverride`, truncated to 63 characters | `fullname`, labels, selector labels |
| `hyperdx.fullname` | `fullnameOverride` or `<release>-<name>`, truncated to 63 characters | Most resource names and dependent helpers |
| `hyperdx.labels` | Standard Helm/app labels plus `commonLabels` | Resource metadata throughout the chart |
| `hyperdx.selectorLabels` | Stable name and release-instance labels | App and collector selector helpers |
| `hyperdx.selectorLabelsApp` | Base selector labels plus `component: app` | App Deployment/Service, PDB, NetworkPolicy |
| `hyperdx.selectorLabelsCollector` | Base selector labels plus `component: otel-collector` | Collector Deployment/Service and NetworkPolicy |
| `hyperdx.otelCollectorName` | `<fullname>-otel-collector`, truncated to 63 characters | Collector resources, app exporter endpoint, OTLP ingress |
| `hyperdx.keeperName` | `<fullname>-keeper`, truncated to 63 characters | Keeper CR and ClickHouse `keeperClusterRef` |
| `hyperdx.mongodbName` | `<fullname>-mongodb`, truncated to 63 characters | MongoDB CR and Mongo host derivation |
| `hyperdx.mongoConnectionName` | `<fullname>-mongo-connection`, truncated to 63 characters | MCK connection Secret name and app/CronJob references |
| `hyperdx.mongoScramName` | `<fullname>-mongo-scram`, truncated to 63 characters | MCK SCRAM Secret name |
| `hyperdx.serviceAccountName` | Explicit service-account name, otherwise fullname | Workloads and ServiceAccount |
| `hyperdx.secretName` | `auth.existingSecret`, otherwise fullname | App session-secret reference |
| `hyperdx.clickhouseSecretName` | `clickhouse.auth.existingSecret`, otherwise fullname | Collector password reference |
| `hyperdx.mongodbSecretName` | `mongodb.existingSecret`, otherwise fullname | MongoDB CR password reference |
| `hyperdx.clickhouse.host` | In-cluster operator Service `<fullname>-clickhouse-headless`, or required external host | Init checks, app connection JSON, collector endpoints |
| `hyperdx.clickhouse.httpPort` | `8123` in-cluster; `clickhouse.external.httpPort` externally | Init checks and app connection JSON |
| `hyperdx.clickhouse.nativePort` | `9000` in-cluster; `clickhouse.external.nativePort` externally | Collector native endpoint |
| `hyperdx.mongo.host` | `<mongodbName>-svc`, truncated to 63 characters | App init check when MCK is enabled |
| `hyperdx.image` | `repository@digest` when digest is non-empty; otherwise `repository:tag` | HyperDX, collector, and alert CronJob images |
| `hyperdx.persisted` | Explicit value, existing release-Secret value via `lookup`, or a new 32-character random value | Session and MongoDB passwords in `secret.yaml:17,20` |
| `hyperdx.clickhousePassword` | Existing-Secret, explicit, or retained release-Secret password; fails when first-install input is absent | `secret.yaml:3-4`; ClickHouse users in `clickhouse-cluster.yaml:69,75` |
| `hyperdx.clickhouseCollectorUser` | Required in-cluster or external collector username | Collector env and connection construction |
| `hyperdx.clickhouseAppUser` | Required in-cluster or external app username | `default-connections` in `secret.yaml:21` |

Derived Kubernetes names use `trunc 63 | trimSuffix "-"` (`_helpers.tpl:1-24,36`). Keep
that rule when adding name helpers. The in-cluster ClickHouse hostname is operator-derived,
not a documented API; keep it centralized in `hyperdx.clickhouse.host` (`_helpers.tpl:29`).

## Credential model

- **ClickHouse passwords are mandatory on first install.** Supply
  `clickhouse.auth.collectorPassword` and `clickhouse.auth.appPassword`, or
  `clickhouse.auth.existingSecret`. The chart deliberately `fail`s otherwise
  (`_helpers.tpl:42-58`). Helm does not memoize helper results: calling `randAlphaNum` from
  `secret.yaml` and `clickhouse-cluster.yaml` would generate different values. The Secret
  and `ClickHouseCluster` CR would disagree, provisioning ClickHouse with credentials the
  app and collector never send.
- On upgrade, `lookup` reads the retained release Secret and reuses its values. This keeps
  ClickHouse, MongoDB, and session credentials stable (`_helpers.tpl:38-58`;
  `secret.yaml:10-20`). **This does not work under Argo CD:** its Helm rendering does not
  provide live-cluster `lookup` results. Supply credentials explicitly or through the
  supported existing-Secret paths.
- `auth.existingSecret` supplies the app session secret. Expected key:
  `express-session-secret` (`hyperdx-deployment.yaml:73-74`).
- `clickhouse.auth.existingSecret` supplies both ClickHouse passwords. Expected keys default
  to `clickhouse-collector-password` and `clickhouse-app-password`; override them with
  `existingSecretCollectorPasswordKey` and `existingSecretAppPasswordKey`
  (`values.yaml:132-134`). The helper fails if the Secret or either requested key is absent.
- `mongodb.existingSecret` supplies the MCK user password. Expected key:
  `mongodb-password` (`mongodb.yaml:17-19`).
- For an external MongoDB, `mongodb.external.connectionStringSecret` expects the key named
  by `connectionStringSecretKey` (default `connectionString.standardSrv`); alternatively set
  `mongodb.external.uri` (`hyperdx-deployment.yaml:58-62`).
- External ClickHouse credentials come from `clickhouse.external.{collectorUser,
  collectorPassword,appUser,appPassword}` or `clickhouse.auth.existingSecret`; they are never
  generated (`_helpers.tpl:50-51,60-61`).

## Editing rules and invariants

- Deployment and PDB `spec.selector` fields are **immutable**. Do not change selector labels
  in place. A label migration requires uninstall/reinstall (`hyperdx-deployment.yaml:8-15`,
  `otel-collector-deployment.yaml:9-16`, `poddisruptionbudget.yaml:9-11`).
- The images need different pod security contexts (`values.yaml:37-41,78-82`): HyperDX's
  image user `node` is non-numeric, so it needs `runAsUser: 1000`; the collector image is
  `uid=10001(otel)` and must **not** be overridden, or its supervisor agent crashes.
- Init containers use busybox, which defaults to root. Keep an explicit numeric `runAsUser`
  and `runAsGroup` (`hyperdx-deployment.yaml:32-38`, `otel-collector-deployment.yaml:29-35`).
- ClickHouse grants must be `grants.query: [ ... ]`. A list of `{query: ...}` maps reaches
  the config intact, but ClickHouse silently keeps only the first entry. Users then have no
  effective privileges and cannot be repaired with SQL `GRANT` because `users_xml` is
  read-only (`clickhouse-cluster.yaml:53-80`).
- The collector grant must include `CREATE TABLE`; `CREATE` alone fails with ClickHouse code
  497 (`clickhouse-cluster.yaml:64-73`).
- Never lower `background_pool_size` in `clickhouse.extraSettings`. In particular, values
  that violate ClickHouse's background-pool constraints prevent startup with exit 36
  (`values-small.yaml:27-30`).
- `DEFAULT_SOURCES` is consumed by `setupTeamDefaults()` only when a team is created.
  Changing `hyperdx.defaultSources` after first registration does not update that team
  (`configmap.yaml:8-13`, `hyperdx-deployment.yaml:71-72`).

## Operator CR gotchas

- `ClickHouseCluster.spec.keeperClusterRef` is required unconditionally, including for one
  shard and one replica (`clickhouse-cluster.yaml:8-14`). Do not emit a cluster without it.
- `spec.image`, `spec.storage`, and `spec.resources` are not valid `ClickHouseCluster`
  fields. Put image/resources under `spec.containerTemplate` and storage under
  `spec.dataVolumeClaimSpec` (`clickhouse-cluster.yaml:14-43`). Keeper uses the same shapes
  (`clickhouse-keeper.yaml:7-23`).
- `versionProbeTemplate` overrides probe-Job resources because the operator default is only
  256Mi and its Job has `backoffLimit: 0`; one OOM is terminal
  (`clickhouse-cluster.yaml:21-35`).

## Adding a new value

1. Add it to `values.yaml` with a concrete comment; this is the primary user interface.
2. Consume it in the appropriate template. Guard optional resources with `{{- if ... }}`
   and render user maps with `toYaml | nindent`.
3. Add its type and constraints to `values.schema.json`.
4. Add or update a `ci/*.yaml` profile if the branch needs render coverage.
5. Add the value to the chart README values table.

## Verification

Renders now require credentials:

```bash
helm lint charts/hyperdx
helm template t charts/hyperdx --set clickhouse.auth.collectorPassword=a --set clickhouse.auth.appPassword=b --set mongodb.password=c --set auth.sessionSecret=d
```

Render the external-backend path:

```bash
helm template t charts/hyperdx \
  --set clickhouse.enabled=false \
  --set clickhouse.external.host=ch.example.com \
  --set clickhouse.external.collectorUser=otelcollector \
  --set clickhouse.external.collectorPassword=a \
  --set clickhouse.external.appUser=app \
  --set clickhouse.external.appPassword=b \
  --set mongodb.enabled=false \
  --set mongodb.external.uri=mongodb://x/y \
  --set auth.sessionSecret=d
```

With the operators/CRDs installed and credentials supplied, use server-side validation:

```bash
helm template t charts/hyperdx \
  --set clickhouse.auth.collectorPassword=a \
  --set clickhouse.auth.appPassword=b \
  --set mongodb.password=c \
  --set auth.sessionSecret=d \
  | kubectl apply --dry-run=server -f -
```

Render every `ci/*.yaml` profile after relevant changes. A bare `helm template t
charts/hyperdx` with no credentials is **expected to fail**: that is the P0-2 first-install
credential guard working, not a bug.

For behaviour (not just rendering), run the real-cluster test against any kubectl
context: `hack/e2e.sh` (fresh install + registration gate + auth matrix + ingest
assert), or with `E2E_UPGRADE_FROM_REF=origin/main` for the upgrade/credential-retention
path. CI runs both on kind (`.github/workflows/e2e.yaml`).
