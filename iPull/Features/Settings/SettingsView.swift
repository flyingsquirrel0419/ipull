import SwiftUI
import AppStoreCore

/// The account sheet, modelled on the App Store's: a profile card on top,
/// then storage, diagnostics and about.
struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AccountView() } label: { profileRow }
                }

                Section("Storage") {
                    LabeledContent("Used by IPAs", value: ByteFormat.string(environment.storage.totalStorageBytes()))
                    if let free = environment.storage.freeDiskBytes() {
                        LabeledContent("Available", value: ByteFormat.string(free))
                    }
                }

                Section {
                    if let logURL = Log.logFileURL {
                        ShareLink(item: logURL) {
                            Label("Share Debug Log", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Logs are redacted: no passwords, tokens or DSIDs are written.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                } footer: {
                    Text("iPull downloads App Store packages for apps on your own Apple Account. It does not bypass DRM, sign, or install apps.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var profileRow: some View {
        HStack(spacing: 14) {
            AccountAvatar(name: environment.session?.displayName, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                if let session = environment.session {
                    Text(session.displayName).font(.title3.weight(.semibold))
                    Text(session.email).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Sign In").font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Text("Apple Account for downloads").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
