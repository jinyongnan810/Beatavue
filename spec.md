# Beatavue — Project Specification

Status: Draft for implementation  
Updated: 2026-10-05

## Purpose

Beatavue is a single-owner demonstration app for viewing the project owner's personal heart data collected in Apple Health. The core experience is a Swift iOS app with a watchOS companion. A later scope adds cloud synchronization, a Django API, a database, and a publicly accessible React web dashboard.

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
| Django API, Firestore, public React dashboard, private upload token | Excluded | Included |
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
Apple Watch → HealthKit → iOS local cache/upload queue → Django API → Firestore
                                                          ↑
                                                   React dashboard
```

- iOS remains the bridge between HealthKit and the server. There is no direct HealthKit-to-server integration.
- Run containerized Django on Google Cloud Run in the same Firebase/Google Cloud project.
- Serve the React and TypeScript dashboard through Firebase Hosting, with API routing to Cloud Run.
- Use a single server-configured owner dataset, public read endpoints, and a private API token for mutation endpoints. No user accounts or sign-in flow are needed.
- Use Cloud Firestore for cloud persistence, accessed by Django through the supported Python server client.
- Use Django REST Framework for API validation and serialization. Firestore persistence uses a repository/service layer rather than Django ORM models; do not require database-backed Django sessions or admin for this demo.

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
- Configure the app for the single owner dataset. Changing the server endpoint or replacing the dataset requires resetting pending uploads and sync state before an explicit new import. Rotating a token for the same dataset does not require reimporting history.
- Define how deleted cloud data stays deleted: disable uploads and reset/purge relevant pending data when the user deletes their cloud history, until they explicitly opt in to importing again.

Background synchronization is best effort and eventual. There is no guarantee of upload while force-quit, locked, offline, or otherwise restricted, and no fixed upload interval. Backend availability cannot cause new HealthKit measurements to be collected.

### Public viewing and owner-only mutations

- No user registration, sign-in screen, Firebase Authentication, or web access gate.
- Allow unauthenticated reads of the owner's published heart-rate and HRV data and public ingestion status through the API.
- Require a high-entropy private bearer token for uploads, updates, and deletions; validate it in Django before performing any mutation.
- Store the token in iOS Keychain and make it available to the backend through Secret Manager. Support token rotation without changing sample identifiers.
- Never place the token in React assets, URLs, logs, repository files, or Terraform configuration/state. Provision the secret value separately from its Terraform-managed container.
- Derive the dataset identifier from server configuration, never from a client-supplied owner field. Reject attempts to address other datasets.
- Deny direct mobile/web access to Firestore; access the database through the API.
- Allow public invocation of the Cloud Run API, with Django enforcing token authorization on every mutation endpoint. Use a Cloud Run service identity with appropriate database IAM permissions; Firestore server libraries bypass Firebase Security Rules.
- Use HTTPS and avoid logging sample values or full upload payloads.
- Return only fields required for graphs and public summaries; keep internal sample UUIDs and device provenance out of public responses. Show a generic source label when useful, without device identifiers.
- Bound public query ranges, pagination sizes, and request rates to keep the demo's database reads predictable.
- Provide owner-only deletion of uploaded health data and disabling of future uploads in iOS. The public web dashboard has no mutation controls.

### Data model

Store raw samples under one server-configured owner dataset, using a deterministic identifier based on the HealthKit sample UUID. There is no user/account collection or multi-user routing.

Each sample includes:

- Dataset identifier, fixed by server configuration.
- HealthKit sample UUID.
- Metric (`heart_rate` or `hrv_sdnn`).
- Numeric value and canonical unit (`bpm` or `ms`).
- Measurement start and end timestamps in UTC.
- Source app identifier/name and available device provenance.
- Server ingestion timestamp and schema version.

Preserve different UUIDs from different sources rather than merging samples solely by timestamp. Define a consistent source selection policy for charts to avoid confusing overlapping sources.

Synchronize deletions with ordered operations or tombstones so retried older additions cannot resurrect deleted samples. Keep chart summaries rebuildable from raw data.

### API contract

| Endpoint | Access | Responsibility |
| --- | --- | --- |
| `POST /v1/sync` | Private bearer token | Accept bounded batches of sample additions and deletions; acknowledge only durably persisted changes |
| `GET /v1/samples` | Public | Return a published metric over a bounded time range, with pagination |
| `GET /v1/summaries` | Public | Return chart buckets and sample-based summaries for a time range and display timezone |
| `GET /v1/sync-status` | Public | Return last successful server ingestion time; omit internal errors, credentials, and device details. Local queue status remains an iOS responsibility |
| `DELETE /v1/data` | Private bearer token | Delete the owner's uploaded health data |

- Validate metric types, units, timestamps, payload size, and batch limits.
- Make ingestion idempotent, with explicit per-batch or per-operation acknowledgment semantics.
- Support incremental/paginated reads and return clear authentication, validation, retryable, and persistence errors.
- Preserve the distinction between measurement time and upload time.

### React web dashboard

- Open directly for anyone, without sign-in, passwords, or an access gate. The dashboard is read-only and displays the owner's published data.
- Display cloud-synced heart-rate and HRV history with day, week, and month views.
- Show units, measurement timestamps, latest measurements, sample-based summaries, and generic source labels consistently with iOS; omit internal device identifiers.
- Display last server ingestion time and explain that recent device measurements may not yet be uploaded.
- Support date navigation, graph inspection, empty/loading/error states, and a responsive layout.
- Refresh data manually and by lightweight polling while the dashboard is open.
- Keep uploading, cloud-data deletion, and sync controls in the owner's iOS app; do not expose mutation controls or credentials in the public dashboard.
- Live workout streaming to the web is outside this scope. Live HRV remains cancelled.

### Infrastructure and deployment

- Keep Terraform configuration in `infra/` and application deployment scripts/workflows under version control.
- Manage supported resources with Terraform: Firebase/Google Cloud project configuration, API enablement, required Firebase app registrations, Firestore database/indexes/security rules, service accounts/IAM, Artifact Registry, publicly invocable Cloud Run, and Secret Manager secret containers. Firebase Authentication and authentication provider configuration are excluded.
- Use a remote Terraform state backend. Document any one-time bootstrap steps and resource/provider limitations.
- Build and publish Django container images and deploy React assets through CI/CD; Terraform manages infrastructure rather than compiling application code.
- Use Firebase Hosting configuration for the SPA and API routing. Document any Hosting setup not supported by the selected Terraform provider.
- Enable the billing required by Cloud Run/Firebase integration, allow scale-to-zero, set a small maximum instance count, and configure budget alerts. Budget alerts are informational rather than a hard spending cap.
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
| `api/` | Django API, Firestore integration, and backend container |
| `web/` | React dashboard |
| `infra/` | Terraform and infrastructure configuration |

## Technical references

- [Apple: HRV SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)
- [Apple: Building a multidevice workout app](https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app)
- [Apple: Executing observer queries](https://developer.apple.com/documentation/healthkit/executing-observer-queries)
- [Apple: Protecting user privacy](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)
- [Firebase Hosting with Cloud Run](https://firebase.google.com/docs/hosting/cloud-run)
- [Firebase Terraform support](https://firebase.google.com/docs/projects/terraform/get-started)
- [Firestore security overview](https://firebase.google.com/docs/firestore/security/overview)
