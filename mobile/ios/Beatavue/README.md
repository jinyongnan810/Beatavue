# Beatavue Scope 1

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

The two target copies of `WorkoutSnapshot.swift` define the same wire format and must be updated together. No live HRV or cloud synchronization is implemented.

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
