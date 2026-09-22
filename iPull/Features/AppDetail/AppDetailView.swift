import SwiftUI
import SwiftData
import AppStoreCore

struct AppDetailView: View {
    let appID: Int64

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = AppDetailViewModel()
    @State private var showAllVersions = false

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading app…")
            case .failed(let message):
                ContentUnavailableView("Couldn't Load App", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .loaded:
                detailContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAllVersions) {
            VersionsView(viewModel: viewModel)
        }
        .task { await viewModel.load(appID: appID, environment: environment) }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let app = viewModel.app {
            List {
                Section {
                    HStack(spacing: 14) {
                        AsyncImage(url: app.iconURL) { $0.resizable() } placeholder: {
                            RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.headline)
                            if let dev = app.developerName {
                                Text(dev).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Text(app.bundleID).font(.caption).foregroundStyle(.tertiary)
                            Text("App ID \(app.id)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Versions") {
                    switch viewModel.versionState {
                    case .loading:
                        HStack { ProgressView(); Text("Loading versions…").foregroundStyle(.secondary) }
                    case .requiresSignIn:
                        Button("Sign in to browse versions") {
                            // Settings tab hosts the account flow.
                        }
                    case .unavailable(let message):
                        Text(message).foregroundStyle(.secondary).font(.subheadline)
                    case .loaded(let versions):
                        ForEach(versions.prefix(4)) { version in
                            Button { viewModel.select(version) } label: {
                                HStack {
                                    Text(version.displayVersion ?? "Version \(version.externalVersionID)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if version.isLatest {
                                        Text("Latest").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if viewModel.selectedVersion == version {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                        if versions.count > 4 {
                            Button("View All Versions (\(versions.count))") { showAllVersions = true }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.download(environment: environment) }
                    } label: {
                        Text(downloadButtonTitle)
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canDownload)
                    .listRowInsets(EdgeInsets())

                    if let status = viewModel.downloadStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { recordRecent(app: app) }
        }
    }

    private var downloadButtonTitle: String {
        if let selected = viewModel.selectedVersion {
            return "Download \(selected.displayVersion ?? selected.externalVersionID)"
        }
        return "Download IPA"
    }

    private func recordRecent(app: AppStoreApp) {
        let recent = RecentApp(appID: app.id, bundleID: app.bundleID, name: app.name, developerName: app.developerName)
        modelContext.insert(recent)
        try? modelContext.save()
    }
}
