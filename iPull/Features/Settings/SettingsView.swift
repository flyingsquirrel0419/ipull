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

                Section("About") {
                    LabeledContent("Version", value: "1.0")
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
