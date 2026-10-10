import SwiftUI

/// Owner-only publishing controls are available only in the iPhone app.
struct CloudSyncView: View {
    let sync: CloudSync
    @State private var endpoint = ""
    @State private var token = ""
    @State private var confirmPublish = false
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var olderDate = Date()

    var body: some View {
        Section("Cloud publishing") {
            Text("Publishing makes your heart-rate and HRV history visible to anyone on the web. Health permission alone does not enable publishing.")
            TextField("HTTPS API base URL", text: $endpoint)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Private upload token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save connection") {
                Task {
                    await sync.configure(endpoint: endpoint, token: token)
                    token = ""
                }
            }.disabled(!sync.ready || sync.working)
            Text("Changing the endpoint resets local sync and requires a new publishing confirmation. A blank token keeps the existing Keychain token.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Publishing", value: sync.state.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
            LabeledContent("Pending changes", value: sync.pendingCount.formatted())
            if let date = sync.state.lastUpload {
                LabeledContent("Last successful upload") { Text(date, format: .dateTime.month().day().hour().minute()) }
            }
            if let error = sync.error { Text(error).foregroundStyle(.orange) }
            if sync.state.enabled {
                Button("Pause publishing") { sync.disable() }
                Button("Sync now") { Task { await sync.syncNow() } }
                DatePicker("Import history from", selection: $olderDate, in: ...Date(), displayedComponents: .date)
                Button("Publish older history") { confirmPublish = true }
            } else {
                Button("Enable public publishing") { confirmPublish = true }
                    .disabled(!sync.ready || sync.working || sync.state.deletionID != nil)
            }
            Button("Delete cloud history", role: .destructive) { confirmDelete = true }
                .disabled(sync.working || sync.state.generation == nil)
            Button("Reset local sync", role: .destructive) { confirmReset = true }
                .disabled(sync.working || sync.state.deletionID != nil)
            Text("Background delivery is best effort. Open the app to catch up after being offline or force-quit. Pausing leaves published cloud history visible; deletion removes it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { endpoint = sync.state.endpoint }
        .confirmationDialog("Publish your Health history for anyone to view?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Publish history") {
                Task {
                    if sync.state.enabled { await sync.importHistory(from: olderDate) }
                    else { await sync.enable() }
                }
            }
        } message: {
            Text("Initial publishing imports the last 30 days and future measurements. Older imports publish the selected date onward.")
        }
        .confirmationDialog("Delete uploaded cloud history?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete cloud history", role: .destructive) { Task { await sync.deleteCloudData() } }
        } message: {
            Text("Publishing stops and pending uploads are discarded. Your local Apple Health history stays available. Reimport requires a new publishing confirmation after deletion finishes.")
        }
        .confirmationDialog("Reset this device's cloud sync?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset local sync", role: .destructive) { sync.resetLocalSync() }
        } message: {
            Text("Use this if the server dataset was replaced. Pending uploads and anchors are discarded, publishing stops, and a new confirmation is required. Published cloud data stays visible.")
        }
    }
}
