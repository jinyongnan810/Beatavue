# Beatavue — Project Specification

Status: Scope 1 implemented; Scope 2 implemented locally, deployment and device acceptance pending
Updated: 2026-10-10

## Purpose

Beatavue is a single-owner demonstration app for viewing the project owner's personal heart data collected in Apple Health. The core experience is a Swift iOS app with a watchOS companion. A later scope adds cloud synchronization, a serverless HTTP API, a database, and a publicly accessible React web dashboard.

Only the owner's data is collected. Anyone can view the uploaded heart-rate and HRV history on the web without signing in or passing an access gate. Uploading, modifying, and deleting data remain restricted to the owner's iOS app through a private API token. User accounts and Firebase Authentication are not required.

The project demonstrates historical data visualization, live heart-rate display, and reliable synchronization. It does not provide medical diagnosis or emergency monitoring.

## Scope boundaries

| Capability | Scope 1: iOS and watchOS | Scope 2: Cloud and web |
| --- | --- | --- |
| All-day heart-rate history | Included | Sync and web display |
| HRV history (SDNN) | Included | Sync and web display |
| Live heart rate through a watchOS companion | Included | No additional live-streaming requirement |
| Live HRV | Cancelled | Cancelled |
| Automatic background upload from iOS | Excluded | Included |
| Cloud Run functions API, Firestore, public React dashboard, private upload token | Excluded | Included |
| User accounts, sign-in, web access gate | Excluded | Excluded |
| Terraform and cloud deployment | Excluded | Included |

Scope 1 must be usable and demonstrable without a backend or cloud account. Scope 2 extends that working app.

## Scope 1 — iOS app and watchOS companion

### Platforms and technology

- Swift and SwiftUI for iOS and watchOS.
- HealthKit for authorized historical data access and workout-based live heart rate.
- Swift Charts for historical graphs.
- Local persistence for cached history and app settings.
- Physical iPhone and paired Apple Watch for live recording and device validation. Minimum OS versions will be selected during implementation to support the chosen workout mirroring APIs.

### HealthKit access

- Check HealthKit availability and explain the purpose of each requested data type.
- Request read access to heart rate and heart-rate variability SDNN.
- Request only the additional permissions needed for the live workout feature, including workout write access if workouts are saved.
- Configure the HealthKit capabilities and usage descriptions for both targets as required.
- Handle partial authorization and unavailable data gracefully.
- Do not claim to detect denied read permission: HealthKit intentionally hides that status. Use an empty state such as “No accessible data,” with guidance to check Health permissions.

### Heart-rate history

- Display all available heart-rate samples across the selected day, in beats per minute (bpm).
- Provide day, week, and month views, with date navigation.
- Initially import the preceding 30 days; allow additional history to be loaded when the user selects older dates.
- Show the latest sample and its measurement timestamp, plus sample-based minimum, maximum, and average for the selected period.
- Allow graph inspection to reveal value, timestamp, and source.
- Refresh history when the app opens, returns to the foreground, or the user requests a refresh.
- Preserve gaps and distinguish measured samples from aggregated chart points. Do not fabricate readings or imply continuous all-day recording.
- Clearly label averages as averages of available samples, rather than time-weighted physiological averages.

“All-day history” means viewing the available measurements over a full day. Apple Watch background sampling is intermittent, and Watch-to-iPhone synchronization may delay availability.

### HRV history

- Read HealthKit's heart-rate variability SDNN samples and display values in milliseconds (ms).
- Provide day, week, and month views, with timestamps and source inspection.
- Show the latest available HRV sample with its measurement time.
- Use discrete points or bars where appropriate so sparse samples do not imply continuous measurement.
- Label the metric “HRV (SDNN).” Do not present it as RMSSD or derive recovery/stress scores.
- Do not attempt to start, compute, or stream live HRV. Live HRV is cancelled for the entire project.

### Live heart rate

- Provide a watchOS companion with start, stop, current heart rate, elapsed time, and session status.
- Use a user-started, workout-based recording session on Apple Watch and HealthKit live workout APIs.
- Clearly identify the session as a workout when starting it; do not use hidden or permanent workout sessions to simulate continuous all-day monitoring.
- Mirror the workout session to the paired iPhone and explicitly send live heart-rate values and timestamps through the supported session communication APIs.
- Display live heart rate and session state on iPhone as well as Apple Watch.
- Show waiting, paused if supported, disconnected, ended, and stale-data states as appropriate. Always show the measurement time; do not keep presenting an old value as current.
- Treat update cadence as sensor/system controlled, with no fixed per-second sampling guarantee.
- Define workout saving behavior explicitly in implementation. If saved, resulting HealthKit heart-rate samples enter the historical view through normal history queries.
- Scope 1 requires no live server or web stream.

### Local data and user experience

- Cache only data needed for the historical views, preserve sample UUIDs and provenance, and reconcile cached data when reloading history.
- Keep the local cache account-independent in Scope 1; it represents the authorized local HealthKit store.
- Normalize units internally and preserve sample start/end timestamps.
- Render dates in the user's selected/display timezone, defaulting to the device timezone, including correct day boundaries and daylight-saving transitions.
- Support loading, empty, error, offline, unavailable-Watch, and disconnected-Watch states.
- Keep cached graphs usable without connectivity and clearly indicate when data was last refreshed.

### Scope 1 acceptance criteria

1. On a physical iPhone with available HealthKit samples, the app displays heart-rate and HRV history for a selected day, week, and month with correct units and timestamps.
2. Graph values match the underlying HealthKit samples; gaps and sparse HRV data remain apparent.
3. Partial permissions and empty stores produce useful states without crashing or falsely reporting read authorization.
4. A user can start and stop a recording session on a paired Apple Watch and see incoming heart-rate values on both devices.
5. Connection loss or missing samples are reflected in the live display rather than silently showing a stale value as current.
6. History remains usable from the local cache without a backend. No live HRV feature is present.

## Scope 2 — Background upload, API, database, web, and infrastructure

### Architecture

```text
Apple Watch → HealthKit → iOS local cache/upload queue → HTTP Cloud Run function → Firestore
                                                          ↑
                                                   React dashboard
```

- iOS remains the bridge between HealthKit and the server. There is no direct HealthKit-to-server integration.
- Run one Python HTTP Cloud Run function in the existing Firebase/Google Cloud project `beatavue` (project number `256425564793`), with a separate IAM-protected deletion worker. Use `asia-northeast1` (Tokyo) for compute and the default Firestore database unless an existing database requires a different location.
- Serve the React and TypeScript dashboard through Firebase Hosting, with API routing to Cloud Run.
- Use a single server-configured owner dataset, public read endpoints, and a private API token for mutation endpoints. No user accounts or sign-in flow are needed.
- Use Cloud Firestore for cloud persistence, accessed by the API through the supported Python server client.
- Use Python Functions Framework for the HTTP entry point, Pydantic for strict validation, and a Firestore repository layer. No Django, relational database, sessions, admin, or account system is required. Keep all `/v1` routes in one public function; cloud-data cleanup runs in a separate private function invoked by Cloud Tasks.

### iOS automatic background synchronization

- Require explicit opt-in to publishing the owner's heart-rate and HRV history to the public dashboard, separate from HealthKit read authorization. No sign-in is required.
- Provision a private API token outside source control and store it in iOS Keychain. Attach it to upload and deletion requests; never include it in the web app.
- Import the initial 30-day window and any older history explicitly requested for synchronization.
- Register `HKObserverQuery` instances for heart rate and HRV, enable HealthKit background delivery, and initialize observers at app launch.
- Use `HKAnchoredObjectQuery` to obtain incremental additions and deletions. Persist anchors by data type and import window.
- Persist retrieved changes and their anchor atomically in a durable local upload queue before acknowledging background processing.
- Upload bounded batches using networking appropriate to background execution, including background URLSession transfers where suitable. Reuse stable identifiers so retries are safe.
- Retry after connectivity failures and temporary server failures with backoff. Remove queued changes only after confirmed server persistence.
- Catch up on app launch, foreground entry, and explicit “Sync now.” Handle locked-device read failures by retrying when data becomes accessible.
- Provide cloud-sync enabled/disabled state, last successful upload, pending change count, and actionable errors.
- Keep the upload queue in a versioned, atomically replaced, fully protected JSON file excluded from device backups. HealthKit anchors and queue additions/deletions are saved together. File-backed background URLSession uploads retain their batch IDs across retries and reattach through UIApplicationDelegate after relaunch. Tokens use device-only Keychain storage available after first unlock.
- Configure the app for the single owner dataset. Changing the server endpoint or replacing the dataset requires resetting pending uploads and sync state before an explicit new import. Rotating a token for the same dataset does not require reimporting history.
- Define how deleted cloud data stays deleted: disable uploads and reset/purge relevant pending data when the user deletes their cloud history, until they explicitly opt in to importing again.

Background synchronization is best effort and eventual. There is no guarantee of upload while force-quit, locked, offline, or otherwise restricted, and no fixed upload interval. Backend availability cannot cause new HealthKit measurements to be collected.

### Public viewing and owner-only mutations

- No user registration, sign-in screen, Firebase Authentication, or web access gate.
- Allow unauthenticated reads of the owner's published heart-rate and HRV data and public ingestion status through the API.
- Require a high-entropy private bearer token for uploads, updates, and deletions; validate it in the HTTP handler before performing any mutation.
- Store the token in iOS Keychain and make it available to the backend through Secret Manager. Support token rotation without changing sample identifiers.
- Never place the token in React assets, URLs, logs, repository files, or Terraform configuration/state. Provision the secret value separately from its Terraform-managed container.
- Derive the dataset identifier from server configuration, never from a client-supplied owner field. Reject attempts to address other datasets.
- Deny direct mobile/web access to Firestore; access the database through the API.
- Allow public invocation of the Cloud Run API, with the HTTP handler enforcing token authorization on every mutation endpoint. Use a Cloud Run service identity with appropriate database IAM permissions; Firestore server libraries bypass Firebase Security Rules.
- Use HTTPS and avoid logging sample values or full upload payloads.
- Return only fields required for graphs and public summaries; keep internal sample UUIDs and device provenance out of public responses. Show a generic source label when useful, without device identifiers.
- Bound public query ranges, pagination sizes, and request rates to keep the demo's database reads predictable.
- Provide owner-only deletion of uploaded health data and disabling of future uploads in iOS. The public web dashboard has no mutation controls.

### Data model

Store raw samples under one server-configured owner dataset, under `datasets/owner/generations/{generation}/samples/{sha256OfUUID}`, using a deterministic SHA-256 identifier based on the normalized HealthKit sample UUID. Keep the UUID in private sample data but omit it from public responses and cursors. There is no user/account collection or multi-user routing.

Each sample includes:

- Dataset identifier, fixed by server configuration.
- HealthKit sample UUID.
- Metric (`heart_rate` or `hrv_sdnn`).
- Numeric value and canonical unit (`bpm` or `ms`).
- Measurement start and end timestamps in UTC.
- Source app identifier/name and available device provenance.
- Server ingestion timestamp and schema version.

Preserve different UUIDs from different sources rather than merging samples solely by timestamp. Both clients include all accessible/published sources with equal sample weighting and explicitly retain overlapping measurements. Public sources use the generic Apple Health label.

Synchronize deletions with tombstones: deletion always wins for a UUID within an import generation. A tombstone retains only deletion metadata and removes sample values and provenance. Keep chart summaries rebuildable from raw data.

- Store a batch receipt under each generation's `batches` subcollection. A transaction checks the generation fence, writes every operation, records a canonical payload digest and acknowledgment, and updates ingestion status. Return success only after transaction commit. A retry with the same batch ID and payload returns the original acknowledgment; conflicting reuse returns HTTP 409.
- `POST /v1/import` accepts a stable `import_id` and returns the active generation. The initial import uses that ID as its generation. Active-dataset reconnects return the existing generation. Retired generation markers prevent old import retries from reopening deleted history.
- `DELETE /v1/data` accepts `generation` and a stable `deletion_id`, disables ingestion transactionally, and schedules durable cleanup. Return HTTP 202 while cleanup is pending, then HTTP 200 on a repeated request after completion. Cloud Tasks retries chunked deletion until raw samples and batch receipts are gone. If enqueueing fails, return HTTP 503; retrying the same deletion schedules it again without removing the fence.
- Reject old-generation uploads even if they match a previous receipt. A new import is allowed only after cleanup completes and an explicit owner opt-in. Retain only health-free generation retirement metadata after deletion.

### API contract

| Endpoint | Access | Responsibility |
| --- | --- | --- |
| `POST /v1/sync` | Private bearer token | Accept bounded batches of sample additions and deletions; acknowledge only durably persisted changes |
| `GET /v1/samples` | Public | Return a published metric over a bounded time range, with pagination |
| `GET /v1/summaries` | Public | Return chart buckets and sample-based summaries for a time range and display timezone |
| `GET /v1/sync-status` | Public | Return last successful server ingestion time; omit internal errors, credentials, and device details. Local queue status remains an iOS responsibility |
| `DELETE /v1/data` | Private bearer token | Disable ingestion and initiate generation-fenced deletion; retry with the same deletion ID to check completion |
| `POST /v1/import` | Private bearer token | Explicitly start or reconnect to an import; return its generation |

- Accept `schema_version: 1`, `generation`, `batch_id`, and `operations` on `/v1/sync`. Each operation contains `kind` (`upsert` or `delete`), `uuid`, and `sample` for additions. Require one operation per UUID per batch. Units must match the metric; values must be positive and finite; timestamps require an explicit timezone and end must not precede start.
- Limit uploads to 100 operations and 256 KiB. Limit raw read pages to 500 samples and time ranges to 32 elapsed days (to cover 31-day calendar months across daylight-saving transitions). Order raw results by start timestamp then deterministic document ID; bind continuation cursors to the generation, metric, and range. Different UUIDs at the same timestamp remain distinct.
- Public reads use `metric`, `from`, and `to` with inclusive start and exclusive end. Summaries also accept an IANA `timezone` and `bucket=hour|day`. Daily buckets follow calendar boundaries in the selected timezone; UTC hour buckets distinguish repeated daylight-saving hours. Summaries scan at most 20,000 samples and return HTTP 422 for a denser range, requiring a shorter selection.
- Apply a shared Firestore-backed public allowance of 60 requests and at most 100,000 reserved sample reads per minute across instances. Return HTTP 429 and `Retry-After: 60` when exhausted. Reserve each query's maximum reads before querying; the allowance is conservative. This demo-wide limit does not depend on untrusted IP headers.
- Send `Cache-Control: no-store` on API responses so CDN/browser caches do not retain a deleted generation. Previously downloaded public data cannot be recalled.
- Make ingestion idempotent, with explicit per-batch or per-operation acknowledgment semantics.
- Support incremental/paginated reads and return clear authentication, validation, retryable, and persistence errors.
- Preserve the distinction between measurement time and upload time.

### React web dashboard

- Open directly for anyone, without sign-in, passwords, or an access gate. The dashboard is read-only and displays the owner's published data.
- Display cloud-synced heart-rate and HRV history with day, week, and month views.
- Show units, measurement timestamps, latest measurements, sample-based summaries, and generic source labels consistently with iOS; omit internal device identifiers.
- Display last server ingestion time and explain that recent device measurements may not yet be uploaded.
- Support date navigation, graph inspection, empty/loading/error states, and a responsive layout.
- Refresh data manually and poll every two minutes only while the dashboard is visible. Day views show raw points; week/month views show explicitly labeled daily sample-average points without interpolation. Provide day/week/month calendar navigation and timezone selection with daylight-saving-aware boundaries.
- Keep uploading, cloud-data deletion, and sync controls in the owner's iOS app; do not expose mutation controls or credentials in the public dashboard.
- Live workout streaming to the web is outside this scope. Live HRV remains cancelled.

### Infrastructure and deployment

- Keep Terraform configuration in `infra/` and application deployment scripts/workflows under version control.
- Manage supported resources with Terraform: existing Google Cloud project identity validation, API enablement, Firestore database/indexes/security rules, service accounts/IAM, Artifact Registry, function source storage, public API and private cleanup functions, Cloud Tasks queue, monitoring, and Secret Manager secret containers. Target the existing project rather than creating a replacement project. Firebase Authentication and authentication provider configuration are excluded.
- Use a private versioned GCS bucket for remote Terraform state, bootstrapped separately. Document enabling Firebase on the existing project and initializing its Hosting site through Firebase CLI. Inspect/import existing resources before applying Terraform, especially the default Firestore database. No Firebase app registration is needed because the browser uses only the HTTP API.
- Package and upload immutable Python function source ZIPs and deploy React assets through CI/CD. Terraform references an uploaded source object; Google Cloud Build builds the function during deployment. Terraform does not archive source code or seed application data. Use pinned Secret Manager versions; retire previous function revisions during token rotation.
- Use Firebase Hosting configuration for the SPA and API routing. Document any Hosting setup not supported by the selected Terraform provider.
- Enable the billing required by Cloud Run/Firebase integration. Set minimum instances to zero, maximum API instances to two, and maximum cleanup instances to one. The API starts at 256 MiB, one CPU, concurrency eight, and a 55-second request timeout; the cleanup worker uses concurrency one and a 60-second timeout. Configure budget alerts (default proposed budget USD 10/month) when a billing account ID is supplied; connect monitoring notification channels during deployment. Budget alerts are informational rather than a hard spending cap.
- Prefer colocating the API and database in a suitable supported region. Choose the region before provisioning the database.
- Keep secrets and health data out of repository files and Terraform seed resources. Inject the private token value outside Terraform so it does not enter state.

### Scope 2 acceptance criteria

1. After explicit public-upload opt-in, the owner's historical heart-rate and HRV samples appear in the web dashboard with matching values and timestamps. Anyone can open it in a fresh browser session without signing in or passing an access gate.
2. Background delivery and eventual upload are demonstrated on physical devices; reopening the app catches up after delays or restrictions.
3. Offline samples survive app restart and later upload without duplicate records.
4. HealthKit deletions propagate to the server, and retries do not resurrect deleted samples.
5. Public read requests succeed without credentials. Upload and deletion requests with a missing or invalid private token are rejected without changing data; valid owner requests succeed. No user accounts or multi-user behavior are implemented.
6. Sync status distinguishes local pending changes, last successful upload, and measurement freshness.
7. Cloud-data deletion and disabling uploads prevent automatic reimport until the user explicitly opts in again.
8. Infrastructure can be reproduced from Terraform plus documented bootstrap/deployment steps; API and web deployment are repeatable.
9. The React build and public API responses contain no private upload token or internal device identifiers. Token rotation invalidates the old token without changing stored history.

## Shared exclusions

- Live HRV collection, computation, or streaming.
- Guaranteed continuous all-day heart-rate measurement or guaranteed real-time cloud sync.
- ECG, arrhythmia detection, medical alerts, stress/recovery scores, or clinical interpretation.
- User accounts, Firebase Authentication, sign-in screens, web access gates, and multi-user support.
- Android client, public App Store launch, and production-scale operations. Public read-only web access is included in Scope 2.

## Repository layout

| Directory | Responsibility |
| --- | --- |
| `mobile/` | iOS app, watchOS companion, and shared Swift code |
| `api/` | Python HTTP and cleanup functions, validation, Firestore repository, and backend tests |
| `web/` | React dashboard |
| `infra/` | Terraform and infrastructure configuration |
| `scripts/` | Deterministic function packaging and deployment helpers |

## Technical references

- [Apple: HRV SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)
- [Apple: Building a multidevice workout app](https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app)
- [Apple: Executing observer queries](https://developer.apple.com/documentation/healthkit/executing-observer-queries)
- [Apple: Protecting user privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)
- [Firebase Hosting with Cloud Run](https://firebase.google.com/docs/hosting/cloud-run)
- [Firebase Terraform support](https://firebase.google.com/docs/projects/terraform/get-started)
- [Firestore security overview](https://firebase.google.com/docs/firestore/security/overview)

## Scope 2 implementation and verification status

The repository contains the API, Terraform, deployment helpers, public dashboard, and iOS opt-in/background-sync integration. Local checks cover API contract/persistence behavior, Firestore SDK integration against the emulator (including concurrent retries and pagination), the React production build, Terraform schema validation, and the iOS/Watch build. These checks do not verify cloud IAM, Firestore indexes/transaction contention, Firebase routing, or physical-device background delivery. No live infrastructure has been provisioned by the implementation task because GCP application-default credentials were unavailable. Follow `infra/README.md` for bootstrap, deployment, and live verification; do not claim the public dashboard is deployed until those steps succeed.
