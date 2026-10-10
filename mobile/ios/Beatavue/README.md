# Beatavue iPhone and Watch

Beatavue displays local Apple Health heart-rate and HRV (SDNN) history and mirrors an explicitly started Apple Watch workout to iPhone. Scope 1 requires no server, account, or network upload.

## Setup and use

Open `Beatavue.xcodeproj` in Xcode. The app targets iOS 17 and watchOS 10 or later. Both targets have the HealthKit entitlement and privacy descriptions; the Watch app has the workout-processing background mode. Use a signing team with HealthKit support when installing on physical devices.

On iPhone, select **Review Health permissions** to request heart-rate and HRV read access. Existing permissions can be managed in the Health app’s privacy settings for Beatavue. An empty result means no accessible data; the app does not infer denied read permission. Queries begin after the authorization prompt has completed at least once.

History initially imports the current day and preceding 29 calendar days. Selecting an older day, week, or month imports that period too. Refresh runs on launch, foreground entry, date navigation, pull to refresh, and the Refresh button. Timezone selection defaults to the device timezone.

On Apple Watch, select **Start workout** and confirm the Other workout. Allow heart-rate read access and workout saving. Pause and resume exclude paused time from the active duration. **Stop and save** ends collection and saves the workout to Apple Health; a save failure is shown explicitly. Saved measurements appear in iPhone history after normal Health synchronization.

## History and live data

Charts show raw sample points from all accessible sources without interpolation or aggregation. Touch a chart to inspect the nearest actual timestamp and source; measurements sharing that timestamp remain individually inspectable. The sample list shows every sample in the selected period. Minimum, maximum, and average use the available samples, with equal weight per sample.

The local cache preserves UUIDs, start/end times, source app identifiers and versions, and available device names/models. Successful queries replace samples inside the refreshed interval to reconcile deletions and access changes. Failed queries preserve the cache. The JSON cache uses complete file protection, atomic replacement, and exclusion from device backups; it is independent of accounts.

The Watch sends heart rate, its measurement timestamp, workout state, and active elapsed time through HealthKit workout mirroring. A five-second status heartbeat describes session connectivity; it does not control sensor sampling. Both screens mark measurements older than 30 seconds as stale. iPhone marks an active connection delayed after 15 seconds without a session update. After disconnection, select **Reconnect iPhone** on Watch while recording continues locally.

The two target copies of `WorkoutSnapshot.swift` define the same wire format and must be updated together. No live HRV is implemented.

## Optional cloud publishing (Scope 2)

Deploy the backend and public dashboard using the root `infra/README.md` first. In iPhone
Settings, enter the HTTPS base URL (default `https://beatavue.web.app`) and the private upload
token. Save the connection and explicitly confirm **Enable public publishing**. This imports
the last 30 calendar days and future heart-rate/HRV changes. Anyone can view published data;
Health permission alone does not opt in. Older publication requires the separate date/import action.

`CloudSync` registers HealthKit observers at launch for an enabled import, uses fixed-window
anchored queries, and persists anchors plus immutable upload batches in one atomic protected
file excluded from backups. It uses file-backed background URLSession uploads, reconnects on
background relaunch, and removes batches only on a matching server acknowledgment. Tokens
are stored in device-only Keychain, never in the JSON queue. Temporary failures retain data and
retry with exponential backoff and jitter. Locked-device access failures catch up on foreground
entry or **Sync now**. Background delivery remains best effort and needs physical-device validation.

The durable queue remains completely protected. Only temporary background upload copies use
protection until the first device unlock, allowing the system transfer daemon to reopen them
while locked. Payload timestamps include the full date, time, fractional seconds, and timezone.
On launch, the app recovers queues from the initial time-only timestamp bug by clearing their
anchors and rereading additions from HealthKit, preserving queued deletions and valid batch IDs.
Affected mixed batches get new IDs because their payloads change. Updating the app and tapping
**Sync now** is sufficient; deleting cloud history or resetting local sync is not required.

**Pause publishing** retains the queue but leaves cloud history public. **Delete cloud history**
disables publishing and clears pending local uploads before asking the server to fence and purge
the generation. Tap it again to check deletion completion or retry a failed request; a new import
is disabled until deletion finishes. Changing the endpoint resets local queue/anchors and requires
new opt-in; rotating the token at the same endpoint preserves history and pending batches.
**Reset local sync** is a recovery action for an externally replaced server dataset. It discards
pending uploads and anchors and requires fresh opt-in, while leaving existing cloud history visible.
Local History and Watch workouts continue working without cloud connectivity.

## Verification

Run `make lint`, then build using Xcode MCP `BuildProject`. Do not run test suites unless requested. The iPhone scheme also builds and embeds the Watch app.

Physical-device acceptance remains necessary:

1. Compare heart-rate and HRV points, statistics, timestamps, and sources with Apple Health for a day, week, and month, including an older period.
2. Check partial read permissions and an empty store. Confirm the app says no accessible data without claiming to detect denied read access.
3. Load history, relaunch without connectivity, and confirm cached graphs remain usable. Remove an accessible Health sample, refresh its period, and confirm it is removed from the cache.
4. Start, pause, resume, and stop a workout on a paired Watch. Confirm both devices show matching heart rate and measurement timestamps, and confirm the saved workout appears in Health.
5. Interrupt companion connectivity, confirm the iPhone reports delayed/disconnected updates and stale readings, then reconnect from Watch.
6. Select a timezone with daylight-saving changes and inspect dates around a transition. Check day/week/month boundaries and chart timestamp labels.

Simulator checks can cover navigation, permissions, empty states, and layout. They cannot establish physical sensor accuracy or workout mirroring reliability.
