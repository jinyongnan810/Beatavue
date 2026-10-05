import SwiftUI

#Preview("iPhone tabs") {
    ContentView(history: HistoryStore(), live: PhoneWorkout())
}

#Preview("Settings") {
    /// Selected display timezone identifier; device follows system settings.
    @Previewable @State var timeZoneID = "device"
    SettingsView(timeZoneID: $timeZoneID)
}

#Preview("設定") {
    @Previewable @State var timeZoneID = "device"
    SettingsView(timeZoneID: $timeZoneID)
        .environment(\.locale, Locale(identifier: "ja"))
}

/// Displays the iPhone history, live workout, and settings tabs.
struct ContentView: View {
    /// Shared store for cached and refreshed health history.
    let history: HistoryStore
    /// Shared receiver for mirrored Watch workouts.
    let live: PhoneWorkout
    /// Selected display timezone identifier; device follows system settings.
    @AppStorage("displayTimeZone") private var timeZoneID = "device"

    /// Builds the interface for this view.
    var body: some View {
        TabView {
            HistoryView(store: history)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            PhoneLiveView(workout: live)
                .tabItem { Label("Live", systemImage: "heart.fill") }
            SettingsView(timeZoneID: $timeZoneID)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(.pink)
        .environment(\.timeZone, timeZoneID == "device" ? .autoupdatingCurrent : TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent)
    }
}

/// Displays timezone preferences and health data guidance.
struct SettingsView: View {
    /// Selected display timezone identifier; device follows system settings.
    @Binding var timeZoneID: String
    /// Known timezone identifiers offered by the picker.
    private let zones = TimeZone.knownTimeZoneIdentifiers

    /// Builds the interface for this view.
    var body: some View {
        NavigationStack {
            Form {
                Section("Timezone") {
                    Picker("Timezone", selection: $timeZoneID) {
                        Text("Device").tag("device")
                        ForEach(zones, id: \.self) { zone in Text(zone).tag(zone) }
                    }
                }
                Section("Your data") {
                    Text("Stored on this iPhone. No internet needed.")
                    Text("Watch data appears after syncing.")
                }
                Section("Workouts") {
                    Text("Start on Apple Watch. Stop to save to Health.")
                    Text("HRV is available in History.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
