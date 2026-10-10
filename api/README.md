# Serverless API

Python Functions Framework exposes one HTTP function (`api`) and a separately deployed,
IAM-protected deletion function (`cleanup`). Firestore server access uses the runtime
service account. The public function authenticates mutations with a private bearer token;
there are no accounts. All routes use the server-configured `owner` dataset.

## Local development

From the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r api/requirements-dev.txt
cd api
../.venv/bin/python -m pytest -q
../.venv/bin/functions-framework --target api --port 8080
```

For local persistence, run `firebase emulators:start --only firestore --project demo-beatavue`
from the repository root (Java 21+ and Firebase CLI required), then set `FIRESTORE_EMULATOR_HOST=127.0.0.1:8081`
and `GOOGLE_CLOUD_PROJECT=demo-beatavue`. Never point development mutations at real health data.
Use an independently generated test `UPLOAD_TOKEN` supplied through the environment.
An emulator must already be running; the contract tests themselves require no cloud credentials.
The in-memory test adapter checks persistence decisions and atomic commit boundaries.
Optional SDK integration tests run when `FIRESTORE_EMULATOR_HOST=127.0.0.1:8081` is set;
they use unique `demo-beatavue-test-*` namespaces and verify concurrent retries, actual
query pagination, summaries, and the cleanup handler. Live IAM and index validation remains
required because the emulator does not enforce production indexes or service account IAM.

## Wire contract

All timestamps are ISO 8601 with an explicit timezone. Ranges include `from` and exclude `to`.
Responses always use `Cache-Control: no-store`. Mutation errors omit original payloads.

1. `POST /v1/import`, private: `{"import_id":"<stable UUID>"}` → `{"generation":"<UUID>"}`.
   Reconnects to an enabled dataset return its existing generation. Persist this result locally.
2. `POST /v1/sync`, private:

```json
{
  "schema_version": 1,
  "generation": "<UUID from import>",
  "batch_id": "<stable UUID retained for all retries>",
  "operations": [
    {
      "kind": "upsert",
      "uuid": "<HealthKit sample UUID>",
      "sample": {
        "uuid": "<same HealthKit sample UUID>",
        "metric": "heart_rate",
        "value": 72.5,
        "unit": "bpm",
        "start": "2026-10-09T01:00:00.123Z",
        "end": "2026-10-09T01:00:00.123Z",
        "source_name": "Apple Health",
        "source_identifier": "com.apple.health"
      }
    }
  ]
}
```

This is a synthetic contract example, not published data. `hrv_sdnn` uses `ms`.
Optional private metadata: `source_version`, `device_name`, `device_model`.
A deletion operation is `{"kind":"delete","uuid":"<UUID>"}` with no sample.
Each UUID occurs once per batch, with at most 100 operations and 256 KiB.

Success returns `batch_id`, `generation`, `acknowledged` (operation count), and `ingested_at`.
The entire batch is committed or none is. A duplicate returns its original acknowledgment.
Changed payloads reusing the ID conflict. Deletion tombstones discard values/provenance;
late additions to tombstoned UUIDs are acknowledged as no-ops.

3. `GET /v1/samples?metric=heart_rate&from=...&to=...&limit=500&cursor=...`, public:
   `{"samples":[{"value":72.5,"unit":"bpm","start":"...","end":"...","source":"Apple Health"}],"next_cursor":null}`.
   Range ≤32 elapsed days, allowing 31-day calendar months across DST transitions. Cursors are opaque, tied to the query, and contain hashed document IDs,
   not HealthKit UUIDs. Reads use live pagination rather than a cross-page snapshot; refresh
   after concurrent ingestion to obtain a new view. A generation change invalidates cursors.
4. `GET /v1/summaries?metric=hrv_sdnn&from=...&to=...&timezone=Asia%2FTokyo&bucket=day`, public:
   returns `buckets`, full-range `summary`, `latest` **within the range**, `unit`, `timezone`, `bucket`.
   Statistics contain `count`, `min`, `max`, `average`; empty statistics use null values.
   Day buckets use local calendar days, hour buckets use UTC hours. At most 20,000 raw
   samples are scanned; a dense range returns 422 rather than an incomplete summary.
5. `GET /v1/sync-status`, public: `{"last_ingestion":"..."}` or null. No queue/device details.
6. `DELETE /v1/data`, private: `{"generation":"<UUID>","deletion_id":"<stable UUID>"}`.
   Returns 202 with `cleanup_pending: true`; the active dataset is disabled immediately.
   Retry the same request until 200 with `cleanup_pending: false`. On a task-enqueue 503,
   retrying the same deletion ID recovers scheduling. A new import is blocked until cleanup
   finishes. Cloud Tasks runs cleanup in 200-document chunks and retries failures.

Private calls require `Authorization: Bearer <token>`. Never put it in a URL or web assets.
The token must contain at least 32 characters; deploy a randomly generated high-entropy value.
Use the same-origin Firebase Hosting API URLs for web requests; cross-origin browser requests
are intentionally not enabled. The native app may use Hosting or the HTTPS function base URL.

## Errors and resource bounds

| Status | Meaning | Client action |
|---|---|---|
| 400 | Invalid fields, metric/unit, timestamps, range, or cursor | Correct the request; retain the batch |
| 401 | Missing/invalid token | Replace token; retain the batch |
| 409 | Stale/disabled generation, cleanup pending, or conflicting batch | Resolve import state; retain the batch |
| 413 | Oversized payload | Correct batch construction |
| 422 | Summary range contains over 20,000 samples | Select a shorter period |
| 429 | Shared public allowance exhausted | Honor `Retry-After: 60` |
| 503 | Persistence/task service temporarily unavailable | Retry with the same IDs and backoff |

The public allowance is 60 requests and 100,000 reserved sample reads per minute, shared
through a Firestore transaction across instances. It includes the direct function URL.
Limits reduce accidental/public abuse but are not a hard billing cap. Receipts and tombstones
remain until deleting the generation; TTL removal would weaken retry/deletion guarantees.
The first version computes bounded summaries on request; persistent precomputed summaries
can be added later if actual traffic or data density requires them.
