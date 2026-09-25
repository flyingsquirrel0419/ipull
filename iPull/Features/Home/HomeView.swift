import SwiftUI
import UIKit
import SwiftData
import AppStoreCore

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecentApp.viewedAt, order: .reverse) private var recents: [RecentApp]

    @State private var input = ""
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack(path: $router.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    getAppCard
                    shortcuts
                    if !recents.isEmpty { recentlyViewed }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("iPull")
            .toolbar { AccountToolbarButton() }
            .navigationDestination(for: AppRouter.Route.self) { RouteDestination(route: $0) }
        }
    }

    // MARK: - Sections

    private var getAppCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GET AN APP")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Paste a link to any app")
                    .font(.title2.weight(.bold))
                Text("App Store links, App IDs and bundle IDs all work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("apps.apple.com/…", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($inputFocused)
                    .onSubmit(resolve)
                    .accessibilityLabel("App link, App ID or bundle ID")
                if !input.isEmpty {
                    Button { input = ""; errorMessage = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button {
                    if let clipboard = UIPasteboard.general.string {
                        input = clipboard
                        resolve()
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.pill)

                Spacer()

                Button("Open", action: resolve)
                    .buttonStyle(.pillProminent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private var shortcuts: some View {
        NavigationLink(value: AppRouter.Route.purchased) {
            HStack(spacing: 14) {
                Image(systemName: "bag.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Purchased").font(.headline).foregroundStyle(.primary)
                    Text(environment.session == nil ? "Sign in to see your apps" : "Apps on your Apple Account")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var recentlyViewed: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Recently Viewed", actionLabel: "Clear") { clearRecents() }
                .padding(.bottom, 8)
            ForEach(Array(recents.prefix(10).enumerated()), id: \.element.persistentModelID) { index, recent in
                Button { router.homePath.append(.appDetail(id: recent.appID)) } label: {
                    AppRow(iconURL: recent.iconURL, name: recent.name, subtitle: recent.developerName ?? recent.bundleID) {
                        Text("View")
                    }
                }
                .buttonStyle(.plain)
                if index < min(recents.count, 10) - 1 {
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    // MARK: - Actions

    private func resolve() {
        errorMessage = nil
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch AppStoreURLParser.parse(trimmed) {
        case .success(let request):
            inputFocused = false
            switch request {
            case .appStoreURL(let id, _), .appID(let id):
                router.homePath.append(.appDetail(id: id))
            case .bundleID, .searchTerm:
                router.selectedTab = .search
                NotificationCenter.default.post(name: .ipullSearchRequested, object: trimmed)
            }
        case .failure(let error):
            errorMessage = error.userMessage
        }
    }

    private func clearRecents() {
        for recent in recents { modelContext.delete(recent) }
        try? modelContext.save()
    }
}

/// An App Store list row: icon, two lines of text and a trailing pill.
struct AppRow<Accessory: View>: View {
    let iconURL: URL?
    let name: String
    var subtitle: String?
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            AppIconView(url: iconURL, name: name, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory()
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
        .environmentObject(AppRouter())
}
