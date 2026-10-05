import SwiftUI

struct ContentView: View {
    let history: HistoryStore
    let live: PhoneWorkout
    @AppStorage("displayTimeZone") private var timeZoneID = "device"

    var body: some View {
        TabView {
            HistoryView(store: history)
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            PhoneLiveView(workout: live)
                .tabItem { Label("Live workout", systemImage: "heart.fill") }
            SettingsView(timeZoneID: $timeZoneID)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(.pink)
        .environment(\.timeZone, timeZoneID == "device" ? .autoupdatingCurrent : TimeZone(identifier: timeZoneID) ?? .autoupdatingCurrent)
    }
}

struct SettingsView: View {
    @Binding var timeZoneID: String
    private let zones = TimeZone.knownTimeZoneIdentifiers

    var body: some View {
        NavigationStack {
            Form {
                Section("Display timezone") {
                    Picker("Timezone", selection: $timeZoneID) {
                        Text("Device timezone").tag("device")
                        ForEach(zones, id: \.self) { zone in Text(zone).tag(zone) }
                    }
                    Text("Dates and day boundaries use this timezone, including daylight-saving changes.")
                }
                Section("Your data") {
                    Text("History is stored only on this iPhone in a protected local cache. It works without a backend or internet connection.")
                    Text("Apple Watch measurements can take time to appear in iPhone Health. Refresh after the devices synchronize.")
                }
                Section("Live workouts") {
                    Text("Start an Other workout in Beatavue on Apple Watch. Stopping saves the workout to Apple Health. Sensor updates are controlled by the system.")
                    Text("Readings older than 30 seconds are marked stale. HRV (SDNN) is history only.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
