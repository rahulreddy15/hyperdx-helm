# AGENTS.md

Guidance for AI agents and humans working in this repository.

## What this repo is

A Helm chart that deploys [HyperDX](https://github.com/hyperdxio/hyperdx) (open-source
observability platform, now branded **ClickStack** under ClickHouse Inc) onto Kubernetes,
using **operator-managed** stateful backends.

It is intended to be **generic and publicly usable**. It is not tailored to any single
organisation. Do not add company-specific defaults, registries, hostnames, or policy.

## What this repo is NOT

- **Not a fork of HyperDX.** We carry no application patches. See "Upstream tracking".
- **Not a source-rebuild pipeline.** We consume upstream-published images. See below.
- **Not a vendored copy of the upstream ClickStack chart.** We deploy the same components
  but make different choices, chiefly around secret handling.

---

## Architecture

Exactly **two** stateful backends. Nothing else — no Redis, no Postgres, no Kafka,
no object store.

| Backend | Holds | Lose it and… |
|---|---|---|
| ClickHouse | All telemetry: logs, traces, metrics, session replay | Telemetry history gone |
| MongoDB | App metadata: users, teams, dashboards, saved searches, alert rules, connections | Config and logins gone, telemetry survives |

Both application workloads are stateless Deployments:

- **hyperdx** — Next.js UI (8080) + Express API (8000) + OpAMP server (4320)
- **otel-collector** — OTLP gRPC (4317), OTLP HTTP (4318), health (13133), metrics (8888), fluentd (24225)

```
Prerequisites — installed separately, NOT by this chart
└── clickstack-operators    ONE chart, bundles BOTH:
      ├── clickhouse-operator    clickhouse.com/v1alpha1
      └── mongodb-kubernetes     mongodbcommunity.mongodb.com/v1  (MCK)

This chart
├── KeeperCluster           1 replica  (mandatory, see below)
├── ClickHouseCluster       1 shard / 1 replica
├── MongoDBCommunity        3 members, SCRAM
├── Deployment  hyperdx
├── Deployment  otel-collector
├── Services, Ingress (UI), Ingress (OTLP)
├── Secret, ConfigMap
└── CronJob     optional alert checker
```

### Operators are prerequisites, never chart dependencies

Operators are cluster-scoped and own CRDs. If this chart installed them, a `helm uninstall`
could remove CRDs still in use by other workloads in the cluster. **Never** add them as
chart dependencies or subcharts.

---

## Decisions already made — do not silently revisit

Each of these was researched and chosen deliberately. If you want to change one, say so
explicitly and explain why; do not just do it.

### ClickHouse: official operator, not Altinity

We use ClickHouse Inc's operator (`clickhouse.com/v1alpha1`, `ClickHouseCluster` +
`KeeperCluster`), not Altinity's (`clickhouse.altinity.com/v1`, `ClickHouseInstallation`).

Rationale: it matches what upstream ClickStack ships, so our wiring stays close to the
tested path.

Known costs, accepted:
- API is still `v1alpha1`
- **A `KeeperCluster` is mandatory** — `keeperClusterRef` is a required field even for a
  single-node, single-replica ClickHouse that will never replicate anything. Altinity
  would let us skip Keeper here. We pay for one extra pod.
- User passwords render into the CR. The official operator has no `valueFrom.secretKeyRef`
  for users, unlike Altinity. This is a real limitation — see "Known limitations".

### MongoDB: MCK with the Community CRD

We use [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes) (MCK —
the unified operator that merged the Community and Enterprise operators; dual-licensed,
Apache 2.0 for the Community use case).

**Use `MongoDBCommunity` (`mongodbcommunity.mongodb.com/v1`).** This is the free path and
needs no Ops Manager or Cloud Manager.

**Never use `MongoDB` or `MongoDBMultiCluster` (`mongodb.com/v1`).** Those are the
Enterprise CRDs; they require MongoDB Enterprise Advanced licensing and a management plane.

The old `mongodb/mongodb-kubernetes-operator` repo is archived — best-effort support ended
November 2025. Don't reference it.

### Images: consume upstream, do not rebuild from source

An earlier plan considered continuously rebuilding upstream from source. **That was cut.**

The upstream build is not hermetic — floating base tags (`node:22.22-alpine`,
`golang:1.26-alpine`), live `yarn install` / `go mod download` / `apk add` at build time.
Rebuilding costs 25–40 minutes per release and still does not produce a reproducible
artifact. Meanwhile upstream's app image already ships `sbom: true` and `provenance: true`.

If images must live in a private registry, **copy the artifact, don't rebuild it**:

```bash
crane copy docker.hyperdx.io/hyperdx/hyperdx:2.34.0 registry.example.com/hyperdx:2.34.0
```

Seconds instead of 40 minutes, and the content digest is preserved.

Caveats worth knowing: the **collector** image does not carry SBOM/provenance flags, and
**nothing upstream is cosign-signed**. Sign on ingest if you care.

---

## Upstream tracking

Canonical source is `hyperdxio/hyperdx`. It is healthy and actively developed — do not
assume it is being deprecated in favour of a ClickHouse-owned repo. ClickStack's README
confirms components stay in separate repositories. Only `hyperdxio/helm-charts` was
archived (2026-03-02), which is the gap this chart fills.

- Release cadence: roughly **weekly**
- Tagging: **per-package** via Changesets — `@hyperdx/app@2.34.0`, `@hyperdx/api@2.34.0`,
  `@hyperdx/otel-collector@2.34.0`. There is no single monorepo version tag.
- Root `package.json` stays at `2.0.0`. The canonical app version is
  `packages/app/package.json`.

### Always pin by digest

Upstream publishes immutable per-version tags (`2.34.0`) **and** floating tags (`2`,
`latest`, `2-nightly`). Chart defaults use the version tag; production should pin the
digest. Never depend on a floating tag.

### The schema diff is the upgrade gate

Before promoting any upstream version bump, diff these three paths between the current and
target upstream revision:

```
docker/otel-collector/schema/seed/     # collector-owned, idempotent
packages/api/migrations/ch/            # API-owned, versioned
packages/api/migrations/mongo/         # API-owned, versioned
```

Empty diff → safe to auto-merge. Non-empty → requires human review.

---

## Gotchas that will bite you

These are non-obvious and have each already caused a wrong assumption once.

### 1. Collector schema does not upgrade existing tables

`packages/otel-collector/cmd/migrate/main.go` applies seed SQL with **no version tracking**,
re-running on every startup. All statements are `CREATE TABLE IF NOT EXISTS`.

It will **not** destroy data. It will **silently fail to migrate** — a changed column type,
codec, or engine never retrofits an existing table. Upgrades look clean while schema quietly
drifts.

By contrast `packages/api/migrations/ch/` and `.../mongo/` **are** versioned. (Down
migrations exist upstream, but rolling back a live schema is untested — treat them as
forward-only in practice.) Respect those.

### 2. Mongo user must authenticate against the app database, not `admin`

In the `MongoDBCommunity` CR, set the user's `db:` to the HyperDX database (`hyperdx`), not
`admin`. MCK builds the connection string from that field; authenticating against `admin`
produces a URI without `authSource=admin`, and Mongoose fails to connect.

Also set `connectionStringSecretName` explicitly so the Secret name is deterministic rather
than the generated `<cr>-<db>-<user>` pattern.

Consume it as:

```yaml
- name: MONGO_URI
  valueFrom:
    secretKeyRef:
      name: <release>-mongo-connection
      key: connectionString.standardSrv
```

### 3. Two ClickHouse users, not one

Upstream splits privileges and so do we:

| User | Grants | Why |
|---|---|---|
| `otelcollector` | `SELECT, INSERT, CREATE, SHOW` on the telemetry DB | It creates its own schema at startup |
| `app` | `SHOW ON *.*`, `SELECT ON system.*`, `SELECT` on telemetry DB | Read-only query path |

### 4. `DEFAULT_CONNECTIONS` must come from a Secret

This env var is a JSON blob that embeds the ClickHouse password. Upstream's chart passes it
as a plain env `value:`, which leaks the password into every rendered manifest and into
`kubectl describe pod`. We build it in the Secret and use `secretKeyRef`.

### 5. Generated passwords must survive `helm upgrade`

Use `lookup` to reuse existing Secret values on upgrade, falling back to `randAlphaNum` only
on install, and keep `helm.sh/resource-policy: keep` on the Secret.

Regenerating `EXPRESS_SESSION_SECRET` on upgrade logs out every user. Regenerating a DB
password breaks the running deployment.

Note also that upstream falls back to a **known hardcoded dev string** if
`EXPRESS_SESSION_SECRET` is unset. It must always be set.

### 6. Collector memory limit must exceed 1.5 GiB

The collector's internal `memory_limiter` is configured around 1.5 GiB. A pod memory limit
at or below that causes OOM kills before the limiter can shed load.

### 7. `enableDatadogReceiver` can be unauthenticated

`ENABLE_DATADOG_RECEIVER=true` opens a Datadog intake receiver on 8126. Current upstream
authenticates it with a `DD-API-KEY` header (the team API key) only when collector auth is
enforced; with no team key it is unauthenticated. The env var is read by the **API server**
(`packages/api/src/config.ts`), which generates the collector's config over OpAMP — setting
it on the collector container does nothing. Default is off and it should stay off unless
the user has made an explicit ingress/NetworkPolicy decision.

### 8. There is no `depends_on` in Kubernetes

Compose expressed ordering (ClickHouse → collector; ClickHouse + Mongo → app). Kubernetes
does not. We use init containers plus generous `startupProbe` thresholds — MCK can take
minutes to reach `status.phase: Running`.

### 9. ClickHouse version couples to schema

The seed SQL has a compatibility split (`00002_otel_logs.sql` vs `00002_otel_logs_compat.sql`
for ClickHouse < 26.2). Upstream compose pins `26.5-alpine`; the upstream ClickStack chart
defaults to `25.7-alpine`. They are **not** synchronised. Pin and test the triple
(HyperDX version + collector version + ClickHouse version) together.

### 10. Operator-generated Service names are not stable API

The official operator currently generates `<cr-name>-clickhouse-headless`. This is derived
from operator internals, not a documented contract. It is centralised in a `_helpers.tpl`
helper — if it breaks, fix it in one place, and verify with
`kubectl get svc -l app.kubernetes.io/managed-by=clickhouse-operator`.

### 11. Telemetry does not flow until a user registers

A freshly installed stack accepts **no** telemetry. The collector starts, reports healthy,
and never binds 4317/4318.

HyperDX pushes the collector's pipeline config over OpAMP, and in
`packages/api/src/opamp/controllers/opampController.ts` the OTLP receiver is attached only
when at least one team has an API key. Teams are created by registration. Before that, the
delivered pipelines receive only from `fluentforward`, the `prometheus` scrape receiver,
and `nop`.

Registration also sets `collectorAuthenticationEnforced: true`, after which OTLP senders
must pass the team API key in an `authorization` header or get 401.

There is no supported unattended provisioning path. Hands-off GitOps needs a scripted
`POST /register/password` after install.

### 12. ClickHouse grants must be `grants.query: [...]`

In `extraUsersConfig`, grants must be a single `query` key holding a **list**:

```yaml
grants:
  query:
    - "GRANT ..."
    - "GRANT ..."
```

A list of single-key maps (`grants: [{query: A}, {query: B}]`) is what the operator's own
examples show, and it reaches the config file on disk completely intact — but ClickHouse
keeps only the **first** entry when converting YAML to XML. The user is created, can
authenticate, and silently holds almost no privileges.

Unrecoverable at runtime: these users live in read-only `users_xml` storage, so a SQL
`GRANT` fails with *"Cannot update user ... because this storage is readonly"*.

`CREATE` alone is also insufficient for the collector — it needs `CREATE TABLE` explicitly,
or it dies on startup with code 497 creating `otel_logs`.

### 13. The two images need different security contexts

Not symmetric. Applying one fix to both breaks the other:

| Image | User | Needs |
|---|---|---|
| `hyperdx` | non-numeric `node` | explicit `runAsUser: 1000`, else `runAsNonRoot` can't verify it and admission fails |
| `otel-collector` | numeric `uid=10001(otel)` | **no** override — forcing 1000 crashes the supervisor's agent on config application |

Init containers (busybox) always need an explicit numeric `runAsUser`.

### 14. The version-probe Job fails terminally

The ClickHouse operator's probe Job uses `backoffLimit: 0`, so one failure is final.
Raising its memory afterwards is not enough — the stale Job must be deleted before the
operator retries:

```bash
kubectl delete job -n <ns> -l clickhouse.com/cluster=<release>
```

The only symptom is `Cannot probe replicas` with no ClickHouse pod, which never mentions
the probe.

### 15. A Ready collector does not mean ingestion works

Readiness hits the health-check extension on 13133, which comes up even when no OTLP
receiver is wired and no pipeline runs. Observed at `1/1 Ready` for over ten minutes while
dropping every send. Check listening ports, not pod status.

---

## Working in this repo

### Layout

```
charts/hyperdx/          the chart
  templates/
  ci/                    values files exercised by CI render checks
docs/                    design notes and runbooks
.github/scripts/e2e.sh   real-cluster e2e (kind in CI, any kubectl context locally)
.github/workflows/       lint/render, e2e on kind, upstream tracking, chart releases
```

### Verify before committing

```bash
helm lint charts/hyperdx
helm template t charts/hyperdx \
  --set clickhouse.auth.collectorPassword=a --set clickhouse.auth.appPassword=b > /dev/null
helm template t charts/hyperdx -f charts/hyperdx/ci/minimal-values.yaml > /dev/null
```

A bare `helm template t charts/hyperdx` with no credentials is **expected to fail** —
that is the first-install credential guard (see charts/hyperdx/AGENTS.md), not a bug.

Also render the external-backend path, since it is easy to break:

```bash
helm template t charts/hyperdx \
  --set clickhouse.enabled=false --set clickhouse.external.host=ch.example.com \
  --set clickhouse.external.collectorUser=otelcollector --set clickhouse.external.collectorPassword=a \
  --set clickhouse.external.appUser=app --set clickhouse.external.appPassword=b \
  --set mongodb.enabled=false --set mongodb.external.uri=mongodb://x/y > /dev/null
```

A change is not done until every `ci/*.yaml` values file renders cleanly.

### Conventions

- Chart version bumps on any template or values change. `appVersion` tracks upstream
  HyperDX and changes only on an image bump.
- Every value gets a comment in `values.yaml`. It is the primary user interface.
- Guard optional resources with `{{- if }}`; use `toYaml | nindent` for user-supplied maps.
- Never hardcode a namespace. Never hardcode a registry other than the upstream default.
- No secrets, hostnames, or cluster-specific values committed anywhere.

### Style

- Prefer adding a value over hardcoding, but do not add values nobody will set.
- Keep the default install working with zero configuration on a cluster that has both
  operators — the only thing a user should *have* to set is `hyperdx.publicUrl` for ingress.

---

## Known limitations

- **ClickHouse user passwords render into the `ClickHouseCluster` CR.** The official
  operator has no Secret reference for users. Anyone with read access to the CR can read
  them. Mitigation is RBAC on the CR. Revisit if the operator adds `secretKeyRef`.
- **No backup story for MongoDB.** MCK Community has no Enterprise backup integration. A
  3-member replica set is availability, not backup. Users need Velero, CSI snapshots, or
  scheduled `mongodump`.
- **OTLP gRPC (4317) over Ingress is awkward.** HTTP (4318) works through a normal Ingress;
  gRPC generally needs controller-specific annotations or a LoadBalancer Service.
- **ClickHouse is single-node by default.** Sharding and replication are untested here.
