# Load testing

Methodology and reproduction steps for the numbers in
[operations.md](operations.md#what-load-testing-showed).

## Setup

- minikube, 6 vCPU / 7 GB allocated, arm64
- Chart installed with `values-small.yaml` (targets 2 vCPU / 4 GB)
- Single-node ClickHouse, single Keeper, single MongoDB member
- Payload: OTLP logs over HTTP, ~300 bytes per record, 500 records per request
- 6 concurrent senders, in-cluster (no ingress in the path)

Everything ran inside the cluster to keep network out of the measurement.

## Prerequisites

Telemetry ingestion is gated on a team existing — see the
[runbook](runbook.md#first-run-telemetry-does-not-flow-until-someone-registers). Register
first, then grab the API key:

```bash
kubectl exec -n <ns> <mongo-pod> -c mongod -- \
  mongosh "mongodb://<user>:<pass>@localhost:27017/hyperdx?authSource=hyperdx" \
  --quiet --eval 'print(db.teams.findOne({}).apiKey)'
```

## Generator

`load.py` — posts OTLP/HTTP with N workers for a fixed duration and reports what was
*accepted*. Accepted is not the same as persisted; always cross-check against ClickHouse.

```python
import json, os, time, urllib.request, threading
from concurrent.futures import ThreadPoolExecutor

URL   = "http://<release>-hyperdx-otel-collector:4318/v1/logs"
KEY   = os.environ["APIKEY"]
BATCH = int(os.environ.get("BATCH", "500"))
DUR   = int(os.environ.get("DUR", "180"))
CONC  = int(os.environ.get("CONC", "6"))

lock  = threading.Lock()
stats = {"ok": 0, "err": 0, "codes": {}, "sent": 0}

def payload(i):
    now = int(time.time() * 1e9)
    recs = [{
        "timeUnixNano": str(now),
        "severityText": "INFO",
        "body": {"stringValue": f"pressure b={i} r={j} " + "x" * 200},
        "attributes": [
            {"key": "batch", "value": {"intValue": str(i)}},
            {"key": "host",  "value": {"stringValue": f"node-{j % 50}"}},
        ],
    } for j in range(BATCH)]
    return json.dumps({"resourceLogs": [{
        "resource": {"attributes": [
            {"key": "service.name", "value": {"stringValue": "pressure"}}]},
        "scopeLogs": [{"logRecords": recs}],
    }]}).encode()

stop = time.time() + DUR

def worker(w):
    i = 0
    while time.time() < stop:
        i += 1
        req = urllib.request.Request(URL, data=payload(w * 100000 + i),
            headers={"Content-Type": "application/json", "authorization": KEY})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                with lock:
                    stats["ok"] += 1
                    stats["sent"] += BATCH
                    stats["codes"][resp.status] = stats["codes"].get(resp.status, 0) + 1
        except Exception as e:
            with lock:
                stats["err"] += 1
                k = str(e)[:50]
                stats["codes"][k] = stats["codes"].get(k, 0) + 1

t0 = time.time()
with ThreadPoolExecutor(CONC) as ex:
    list(ex.map(worker, range(CONC)))
d = time.time() - t0

print(f"DURATION={d:.0f}s OK={stats['ok']} ERR={stats['err']} RECORDS={stats['sent']}")
print(f"ACCEPTED={stats['sent'] / d:.0f} rec/s")
print("CODES:", stats["codes"])
```

## Running it

```bash
kubectl create configmap loadgen -n <ns> --from-file=load.py=./load.py

kubectl run loadgen --rm -i --restart=Never -n <ns> --image=python:3.12-alpine --quiet \
  --overrides='{"spec":{"containers":[{"name":"loadgen","image":"python:3.12-alpine",
    "command":["python","/s/load.py"],
    "env":[{"name":"APIKEY","value":"<team-api-key>"},
           {"name":"BATCH","value":"500"},
           {"name":"DUR","value":"180"},
           {"name":"CONC","value":"6"}],
    "volumeMounts":[{"name":"s","mountPath":"/s"}]}],
    "volumes":[{"name":"s","configMap":{"name":"loadgen"}}]}}'
```

Sample resource usage in parallel (requires metrics-server):

```bash
for i in $(seq 1 13); do
  echo "T+$((i*15))s $(kubectl top pods -n <ns> --no-headers | grep -v loadgen)"
  sleep 15
done
```

## Verifying — the step people skip

HTTP 200 means the collector *queued* the batch. It does not mean the data was written.
Always reconcile:

```bash
kubectl exec -n <ns> <clickhouse-pod> -- clickhouse-client \
  --user <app-user> --password <pw> \
  --query "SELECT count() FROM default.otel_logs WHERE ServiceName='pressure'"
```

Poll this a few times — writes are batched, so the count lags the load by tens of seconds.
Compare against `RECORDS` from the generator. In run 1 these matched exactly at 28,662,500.

Also check whether the collector shed load rather than dropping it:

```bash
kubectl exec -n <ns> <collector-pod> -c otel-collector -- \
  tail -50 /etc/otel/supervisor-data/agent.log
```

That file is the collector's own stderr. **The supervisor does not forward it to pod logs**,
so `kubectl logs` on the collector shows you the supervisor, not the collector.

## Testing the failure mode

To reproduce run 2, starve the collector below its internal `memory_limiter` (~1.5 GiB):

```bash
helm upgrade <release> ./charts/hyperdx -n <ns> -f charts/hyperdx/values-small.yaml \
  --set otelCollector.resources.limits.memory=512Mi \
  --set otelCollector.resources.requests.memory=128Mi \
  ...credentials...
```

Then run the same load. Expect mass connection-refused errors while the pod continues to
report `1/1 Running` with `restarts=0`. Watch collector memory collapse:

```bash
kubectl top pods -n <ns> | grep otel-collector
```

Restore the limit to 2Gi afterwards.

## Interpreting results

| Symptom | Meaning |
|---|---|
| HTTP 503 | `memory_limiter` backpressure. Healthy — it's refusing, not dropping |
| Connection refused | The collector isn't listening. Undersized, or OTLP not wired |
| HTTP 401 | Missing or wrong team API key |
| 200s but no rows | Check `agent.log`; usually a ClickHouse grants problem |
| Rows lag then catch up | Normal batching |

## Known limitations of these numbers

- Synthetic payloads with repeated padding and only 50 distinct host values compress far
  better in ClickHouse than real telemetry
- The host had 6 cores, so CPU was never the binding constraint the way it would be on the
  2-core node the profile is named for
- Logs only — traces and metrics have different write patterns and cardinality
- 3 minutes surfaces backpressure but not merge pressure, disk growth, or TTL behaviour
- Single-node ClickHouse; no replication overhead measured
