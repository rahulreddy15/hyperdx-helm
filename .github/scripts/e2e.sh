#!/usr/bin/env bash
# End-to-end test for the hyperdx chart against a real cluster (kind in CI; any
# kubectl context locally). Installs the operators if their CRDs are absent, installs
# the chart, then walks the full ingestion path:
#
#   1. assert the collector does NOT listen on OTLP ports before registration
#   2. register the first user headlessly
#   3. assert OTLP ports come up, and that auth behaves as documented:
#        no key -> 401, "Bearer <key>" -> 401, bare key -> success
#   4. send one OTLP log record and assert the row lands in ClickHouse
#
# Upgrade mode: set E2E_UPGRADE_FROM_REF (e.g. origin/main) to install that git ref's
# chart first, then upgrade to the working-tree chart and assert that generated
# credentials survive the upgrade unchanged and ingestion still works.
#
# Tunables (env): E2E_NAMESPACE, E2E_RELEASE, E2E_CHART, E2E_VALUES, E2E_TIMEOUT,
# E2E_KEEP=1 (skip cleanup), E2E_INSTALL_OPERATORS=never
set -euo pipefail

NS="${E2E_NAMESPACE:-hyperdx-e2e}"
RELEASE="${E2E_RELEASE:-e2e}"
CHART="${E2E_CHART:-charts/hyperdx}"
VALUES="${E2E_VALUES:-charts/hyperdx/values-small.yaml}"
TIMEOUT="${E2E_TIMEOUT:-20m}"
INSTALL_OPERATORS="${E2E_INSTALL_OPERATORS:-auto}"
UPGRADE_FROM_REF="${E2E_UPGRADE_FROM_REF:-}"

CH_COLLECTOR_PW="e2e-collector-pw"
CH_APP_PW="e2e-app-pw"
EMAIL="e2e@example.com"
PASSWORD="E2ePassword123!e2e"
SERVICE_NAME="e2e-check"

FULL="${RELEASE}-hyperdx"
CURL_IMG="curlimages/curl:8.10.1"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nE2E FAIL: %s\n' "$*" >&2; diagnostics; exit 1; }

diagnostics() {
  set +e
  echo "--- diagnostics ---"
  kubectl get pods -n "$NS" -o wide
  kubectl get clickhousecluster,keepercluster,mongodbcommunity -n "$NS" 2>/dev/null
  kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -25
  for d in "$FULL" "$FULL-otel-collector"; do
    echo "--- logs $d ---"; kubectl logs "deploy/$d" -n "$NS" --tail=40 2>/dev/null
  done
  set -e
}

retry() { # retry <attempts> <sleep> <desc> <cmd...>
  local n=$1 s=$2 desc=$3; shift 3
  for i in $(seq 1 "$n"); do
    if "$@"; then return 0; fi
    sleep "$s"
  done
  fail "timed out waiting for: $desc"
}

curl_in_cluster() { # curl_in_cluster <name> <curl args...>
  local name=$1; shift
  kubectl run "$name" -n "$NS" --rm -i --restart=Never --image="$CURL_IMG" \
    --quiet --command -- curl "$@"
}

install_operators() {
  if [ "$INSTALL_OPERATORS" = never ]; then return 0; fi
  if kubectl get crd clickhouseclusters.clickhouse.com >/dev/null 2>&1 \
     && kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com >/dev/null 2>&1; then
    log "operator CRDs present, skipping operator install"
    return 0
  fi
  log "installing clickstack-operators"
  helm repo add clickstack https://clickhouse.github.io/ClickStack-helm-charts >/dev/null
  helm repo update clickstack >/dev/null
  helm upgrade --install clickstack-operators clickstack/clickstack-operators \
    --namespace clickhouse-operators --create-namespace \
    --set-string 'mongodb-operator.operator.watchNamespace=*' \
    --wait --timeout 10m
}

install_chart() { # install_chart <chart-path>
  log "installing chart $1 into $NS"
  helm upgrade --install "$RELEASE" "$1" \
    --namespace "$NS" --create-namespace \
    --set clickhouse.auth.collectorPassword="$CH_COLLECTOR_PW" \
    --set clickhouse.auth.appPassword="$CH_APP_PW" \
    -f "$VALUES" \
    --wait --timeout "$TIMEOUT"
}

collector_listens() { # collector_listens <port>
  kubectl exec "deploy/$FULL-otel-collector" -n "$NS" -- \
    sh -c "netstat -ltn 2>/dev/null" | grep -q ":$1 "
}

secret_snapshot() {
  kubectl get secret "$FULL" -n "$NS" \
    -o jsonpath='{.data.mongodb-password}{" "}{.data.express-session-secret}{" "}{.data.clickhouse-collector-password}{" "}{.data.clickhouse-app-password}'
}

otlp_status() { # otlp_status <name> <extra curl args...> -> prints http code
  local name=$1; shift
  curl_in_cluster "$name" -s -o /dev/null -w '%{http_code}' \
    -X POST "http://$FULL-otel-collector:4318/v1/logs" \
    -H 'Content-Type: application/json' "$@" -d "$OTLP_BODY"
}

ch_query() { # ch_query <sql>
  kubectl exec "$FULL-clickhouse-0-0-0" -n "$NS" -- \
    clickhouse-client --user app --password "$CH_APP_PW" --query "$1"
}

OTLP_BODY=$(cat <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"$SERVICE_NAME"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"$(date +%s)000000000","severityText":"INFO","body":{"stringValue":"e2e ingest check"}}]}]}]}
EOF
)

# ---------------------------------------------------------------------------

install_operators

if [ -n "$UPGRADE_FROM_REF" ]; then
  log "upgrade mode: installing baseline chart from $UPGRADE_FROM_REF"
  BASE_DIR=$(mktemp -d)
  trap 'git worktree remove --force "$BASE_DIR" 2>/dev/null || true' EXIT
  git worktree add --force "$BASE_DIR" "$UPGRADE_FROM_REF" >/dev/null
  install_chart "$BASE_DIR/charts/hyperdx"
else
  install_chart "$CHART"
fi

log "asserting collector is Ready but NOT listening on OTLP before registration"
kubectl wait --for=condition=available "deploy/$FULL-otel-collector" -n "$NS" --timeout=120s
if collector_listens 4318; then
  # A previous run in this namespace may already have a team; only fail on a
  # genuinely fresh install.
  if [ -z "${E2E_ALLOW_EXISTING_TEAM:-}" ]; then
    fail "collector listens on 4318 before any registration (gate broken, or namespace not clean)"
  fi
else
  log "confirmed: no OTLP listener before registration (readiness lies, as documented)"
fi

log "registering first user"
REG_CODE=$(curl_in_cluster e2e-register -s -o /dev/null -w '%{http_code}' \
  -X POST "http://$FULL:8000/register/password" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"confirmPassword\":\"$PASSWORD\"}")
case "$REG_CODE" in
  2*) log "registered $EMAIL" ;;
  409) log "team already exists (rerun) — continuing" ;;
  *) fail "registration returned HTTP $REG_CODE" ;;
esac

log "waiting for the collector to receive its OTLP pipeline over OpAMP"
retry 36 5 "collector listening on 4318" collector_listens 4318
retry 12 5 "collector listening on 4317" collector_listens 4317

log "fetching team API key from MongoDB"
MONGO_PW=$(kubectl get secret "$FULL" -n "$NS" -o jsonpath='{.data.mongodb-password}' | base64 -d)
# mongosh can print warnings to stdout before the value; keep only the UUID.
API_KEY=$(kubectl exec "$FULL-mongodb-0" -c mongod -n "$NS" -- \
  mongosh "mongodb://hyperdx:$MONGO_PW@localhost:27017/hyperdx?authSource=hyperdx" \
  --quiet --eval 'print(db.teams.findOne({}).apiKey)' \
  | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}' | tail -1)
[ -n "$API_KEY" ] || fail "could not read team API key"

log "asserting OTLP auth behaviour"
NOAUTH=$(otlp_status e2e-noauth)
BEARER=$(otlp_status e2e-bearer -H "authorization: Bearer $API_KEY")
BARE=$(otlp_status e2e-bare -H "authorization: $API_KEY")
log "no key -> $NOAUTH, Bearer -> $BEARER, bare key -> $BARE"
[ "$NOAUTH" = 401 ] || fail "expected 401 without API key, got $NOAUTH"
[ "$BEARER" = 401 ] || fail "expected 401 with 'Bearer' prefix, got $BEARER"
case "$BARE" in 2*) ;; *) fail "expected 2xx with bare key, got $BARE" ;; esac

log "asserting the record landed in ClickHouse"
row_landed() {
  local n
  n=$(ch_query "SELECT count() FROM default.otel_logs WHERE ServiceName='$SERVICE_NAME'") || return 1
  [ "${n:-0}" -ge 1 ]
}
retry 24 5 "row in default.otel_logs" row_landed

if [ -n "$UPGRADE_FROM_REF" ]; then
  log "upgrade mode: capturing credentials, upgrading to working-tree chart"
  BEFORE=$(secret_snapshot)
  install_chart "$CHART"
  AFTER=$(secret_snapshot)
  [ "$BEFORE" = "$AFTER" ] || fail "generated credentials changed across helm upgrade"
  log "credentials survived the upgrade unchanged"

  log "asserting ingestion still works after upgrade"
  retry 36 5 "collector listening on 4318 after upgrade" collector_listens 4318
  POST=$(otlp_status e2e-postupgrade -H "authorization: $API_KEY")
  case "$POST" in 2*) ;; *) fail "post-upgrade send returned $POST" ;; esac
  post_rows() {
    local n
    n=$(ch_query "SELECT count() FROM default.otel_logs WHERE ServiceName='$SERVICE_NAME'") || return 1
    [ "${n:-0}" -ge 2 ]
  }
  retry 24 5 "second row in default.otel_logs" post_rows
fi

log "E2E PASS"

if [ -z "${E2E_KEEP:-}" ]; then
  log "cleaning up (set E2E_KEEP=1 to skip)"
  helm uninstall "$RELEASE" -n "$NS" || true
  kubectl delete pvc --all -n "$NS" --wait=false || true
  kubectl delete secret "$FULL" -n "$NS" || true
fi
