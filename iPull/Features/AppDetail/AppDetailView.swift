import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppStoreCore

struct AppDetailView: View {
    let appID: Int64

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = AppDetailViewModel()
    @State private var showAllVersions = false
    @State private var choosingFolder = false
    @State private var iconFrame: CGRect = .zero

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load App", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await reload() } }.buttonStyle(.pill)
                }
            case .loaded:
                if let app = viewModel.app { detail(app) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAllVersions) {
            VersionsView(viewModel: viewModel)
        }
        // No save folder in Settings: ask where this download should go.
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            let bookmark = try? SaveLocation.bookmark(for: folder)
            startDownload(to: bookmark)
        }
        // Re-run when the account changes so signing in from the account
        // sheet immediately unlocks versions and downloads here.
        .task(id: environment.session?.directoryServicesID) { await reload() }
    }

    private func reload() async {
        await viewModel.load(appID: appID, environment: environment)
        if let app = viewModel.app { recordRecent(app: app) }
    }

    // MARK: - Content

    private func detail(_ app: AppStoreApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(app)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                if let status = viewModel.downloadStatus {
                    Label(status, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                Divider().padding(.horizontal, 20).padding(.top, 20)
                infoStrip(app)
                Divider().padding(.horizontal, 20)

                versions
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                information(app)
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 32)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                AppIconView(url: app.iconURL, name: app.name, size: 28)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://apps.apple.com/app/id\(app.id)")!) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private func header(_ app: AppStoreApp) -> some View {
        HStack(alignment: .top, spacing: 16) {
            AppIconView(url: app.iconURL, name: app.name, size: 118)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { iconFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, frame in iconFrame = frame }
                })
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                if let developer = app.developerName {
                    Text(developer).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                downloadButton
            }
            .frame(minHeight: 118, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if environment.session == nil {
            Button("Sign In") { router.isAccountPresented = true }
                .buttonStyle(.pillProminent)
        } else if let app = viewModel.app {
            DetailDownloadButton(
                manager: environment.downloadManager,
                appID: app.id,
                isResolving: viewModel.isResolving,
                isEnabled: viewModel.canDownload,
                start: requestDownload,
                openDownloads: { router.selectedTab = .downloads }
            )
        }
    }

    /// Use the folder from Settings, or ask for one for this download.
    private func requestDownload() {
        if let bookmark = SaveLocation.defaultBookmark {
            startDownload(to: bookmark)
        } else {
            choosingFolder = true
        }
    }

    private func startDownload(to bookmark: Data?) {
        Task {
            guard await viewModel.download(environment: environment, destinationBookmark: bookmark),
                  let app = viewModel.app else { return }
            if iconFrame != .zero {
                router.flight = IconFlight(iconURL: app.iconURL, name: app.name, from: iconFrame)
            }
        }
    }

    /// The App Store's horizontally scrolling stat strip.
    private func infoStrip(_ app: AppStoreApp) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                stat(title: "VERSION", value: viewModel.selectedVersion?.displayVersion ?? app.currentVersion ?? "—",
                     caption: viewModel.selectedVersion?.isLatest == false ? "Selected" : "Latest")
                statDivider
                stat(title: "SIZE", value: app.fileSizeBytes.map { ByteFormat.string($0) } ?? "—", caption: "IPA")
                statDivider
                stat(title: "PRICE", value: priceText(app), caption: app.storefront?.uppercased() ?? "Store")
                statDivider
                stat(title: "APP ID", value: String(app.id), caption: "Numeric")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }

    private func stat(title: String, value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 96)
        .padding(.horizontal, 6)
    }

    private var statDivider: some View {
        Rectangle().fill(Color(.separator)).frame(width: 0.5, height: 36)
    }

    private func priceText(_ app: AppStoreApp) -> String {
        guard let price = app.price else { return "—" }
        return price == 0 ? "Free" : price.formatted(.number.precision(.fractionLength(2)))
    }

    @ViewBuilder
    private var versions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .loaded(let versions) = viewModel.versionState, versions.count > 4 {
                SectionTitle(title: "Version History", actionLabel: "See All") { showAllVersions = true }
            } else {
                SectionTitle(title: "Version History")
            }

            switch viewModel.versionState {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading versions…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            case .requiresSignIn:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with your Apple Account to browse and download past versions.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Sign In") { router.isAccountPresented = true }.buttonStyle(.pill)
                }
            case .unavailable(let message):
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            case .loaded(let versions):
                VStack(spacing: 0) {
                    ForEach(Array(versions.prefix(4).enumerated()), id: \.element.id) { index, version in
                        VersionRow(version: version, isSelected: viewModel.selectedVersion == version) {
                            viewModel.select(version)
                        }
                        if index < min(versions.count, 4) - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func information(_ app: AppStoreApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Information")
            VStack(spacing: 0) {
                infoRow("Developer", app.developerName ?? "—")
                Divider()
                infoRow("Bundle ID", app.bundleID)
                Divider()
                infoRow("App ID", String(app.id))
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    /// One entry per app, refreshed on every visit (no duplicates).
    private func recordRecent(app: AppStoreApp) {
        let id = app.id
        let existing = (try? modelContext.fetch(FetchDescriptor<RecentApp>(predicate: #Predicate { $0.appID == id }))) ?? []
        for recent in existing { modelContext.delete(recent) }
        modelContext.insert(RecentApp(appID: app.id, bundleID: app.bundleID, name: app.name,
                                      developerName: app.developerName, iconURL: app.iconURL))
        try? modelContext.save()
    }
}

struct VersionRow: View {
    let version: AppStoreVersion
    let isSelected: Bool
    let select: @MainActor () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(version.displayVersion ?? "Version \(version.externalVersionID)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if version.isLatest {
                            Text("LATEST")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    if let date = version.releaseDate {
                        Text(date, style: .date).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
