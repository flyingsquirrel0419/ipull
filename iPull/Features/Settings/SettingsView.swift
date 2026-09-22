import SwiftUI
import AppStoreCore

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink("Apple Account") { AccountView() }
                }

                Section("Storage") {
                    LabeledContent("Used by IPAs") {
                        Text(ByteFormat.string(environment.storage.totalStorageBytes()))
                    }
                    if let free = environment.storage.freeDiskBytes() {
                        LabeledContent("Free on device") {
                            Text(ByteFormat.string(free))
                        }
                    }
                }

                Section("Diagnostics") {
                    if let logURL = Log.logFileURL {
                        ShareLink(item: logURL) {
                            Label("Share Debug Log", systemImage: "doc.text")
                        }
                        Text("Logs are redacted: no passwords, tokens, or DSIDs are written.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "0.1.1")
                    Link("Privacy", destination: URL(string: "https://example.invalid/ipull/privacy")!)
                }

                Section {
                    Text("iPull downloads App Store packages for apps on your own Apple Account. It does not bypass DRM, sign, or install apps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
