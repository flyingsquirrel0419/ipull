import SwiftUI
import UIKit
import SwiftData
import AppStoreCore

/// Home, modelled on the App Store's Today tab: a date eyebrow over a large
/// title with the profile button, one field that takes links and search
/// terms alike, a featured card and a paging shelf of recent apps.
struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecentApp.viewedAt, order: .reverse) private var recents: [RecentApp]
    @Query private var libraryItems: [LibraryItem]

    @State private var input = ""
    @State private var errorMessage: String?
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack(path: $router.homePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    searchField
                    featuredCard
                    tiles
                    if !recents.isEmpty { recentShelf }
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                RecentApp.removeDuplicates(in: modelContext)
                for recent in recents.uniqueByApp where recent.iconURLString == nil {
                    if let url = await environment.iconURL(forAppID: recent.appID) {
                        recent.iconURLString = url.absoluteString
                    }
                }
                try? modelContext.save()
            }
            .navigationDestination(for: AppRouter.Route.self) { RouteDestination(route: $0) }
            .confirmationDialog("Clear Recently Viewed?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { clearRecents() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .textCase(.uppercase)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("iPull")
                    .font(.largeTitle.weight(.bold))
            }
            Spacer()
            Button { router.isAccountPresented = true } label: {
                AccountAvatar(name: environment.session?.displayName, size: 38)
            }
            .accessibilityLabel("Account")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Unified link / search field

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: looksLikeLink ? "link" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                TextField("Search apps or paste a link", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(looksLikeLink ? .go : .search)
                    .focused($inputFocused)
                    .onSubmit(resolve)
                    .accessibilityLabel("Search apps, or paste an App Store link, App ID or bundle ID")
                if input.isEmpty {
                    Button(action: paste) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .accessibilityLabel("Paste")
                } else {
                    Button { input = ""; errorMessage = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("Links, App IDs and bundle IDs open the app. Anything else searches the App Store.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    private var looksLikeLink: Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("://") || trimmed.hasPrefix("apps.apple.com") || trimmed.hasPrefix("itunes.apple.com")
    }

    // MARK: - Featured card

    private var featuredCard: some View {
        NavigationLink(value: AppRouter.Route.purchased) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 0.25, green: 0.36, blue: 0.95), Color(red: 0.55, green: 0.27, blue: 0.93)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "bag.fill")
                    .font(.system(size: 150, weight: .bold))
                    .foregroundStyle(.white.opacity(0.12))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 170, y: -50)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR APPLE ACCOUNT")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Purchased Apps")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                    Text(environment.session == nil
                         ? "Sign in to browse everything you've downloaded."
                         : "Every app you've ever downloaded, ready to pull.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(20)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(CardPressStyle())
        .padding(.horizontal, 20)
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            tile(title: "Library", subtitle: libraryItems.isEmpty ? "No IPAs yet" : "\(libraryItems.count) IPA\(libraryItems.count == 1 ? "" : "s")",
                 symbol: "square.stack.fill", tint: .orange) { router.selectedTab = .library }
            tile(title: "Downloads", subtitle: "Transfers", symbol: "arrow.down.circle.fill", tint: .green) {
                router.selectedTab = .downloads
            }
        }
        .padding(.horizontal, 20)
    }

    private func tile(title: String, subtitle: String, symbol: String, tint: Color,
                      action: @escaping @MainActor () -> Void) -> some View {
        Button { action() } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(CardPressStyle())
    }

    // MARK: - Recently viewed shelf

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently Viewed").font(.title2.weight(.bold))
                Spacer()
                Menu {
                    Button { router.homePath.append(.recents) } label: { Label("See All", systemImage: "list.bullet") }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear All", systemImage: "trash") }
                } label: {
                    Text("See All")
                } primaryAction: {
                    router.homePath.append(.recents)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(80), spacing: 0), count: min(3, shelf.count)),
                          spacing: 16) {
                    ForEach(Array(shelf.enumerated()), id: \.element.persistentModelID) { index, recent in
                        VStack(spacing: 0) {
                            Button { router.homePath.append(.appDetail(id: recent.appID)) } label: {
                                ShelfRow(recent: recent)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { remove(recent) } label: {
                                    Label("Remove from Recently Viewed", systemImage: "minus.circle")
                                }
                            }
                            if (index + 1) % 3 != 0 && index < shelf.count - 1 {
                                Divider().padding(.leading, 76)
                            }
                        }
                        .containerRelativeFrame(.horizontal) { width, _ in width - 60 }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private var shelf: [RecentApp] { Array(recents.uniqueByApp.prefix(12)) }

    // MARK: - Actions

    /// Links, App IDs and bundle IDs open the app; any other text is handed
    /// to the Search tab verbatim, where it runs immediately.
    private func resolve() {
        errorMessage = nil
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch AppStoreURLParser.parse(trimmed) {
        case .success(.appStoreURL(let id, _)), .success(.appID(let id)):
            inputFocused = false
            input = ""
            router.homePath.append(.appDetail(id: id))
        case .success:
            inputFocused = false
            input = ""
            router.search(trimmed)
        case .failure(let error):
            if trimmed.contains("://") {
                errorMessage = error.userMessage
            } else {
                // Not a recognisable link: search for it rather than refuse.
                inputFocused = false
                input = ""
                router.search(trimmed)
            }
        }
    }

    private func paste() {
        guard let clipboard = UIPasteboard.general.string, !clipboard.isEmpty else { return }
        input = clipboard
        resolve()
    }

    private func remove(_ recent: RecentApp) {
        let appID = recent.appID
        withAnimation {
            for entry in recents where entry.appID == appID { modelContext.delete(entry) }
        }
        try? modelContext.save()
    }

    private func clearRecents() {
        withAnimation {
            for recent in recents { modelContext.delete(recent) }
        }
        try? modelContext.save()
    }
}

/// A shelf cell: icon, one-line name over the developer, vertically
/// centred against the icon, with the View pill trailing.
private struct ShelfRow: View {
    let recent: RecentApp

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(url: recent.iconURL, name: recent.name, size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(recent.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(recent.developerName ?? recent.bundleID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("View")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .frame(height: 79)
        .contentShape(Rectangle())
    }
}

/// The subtle shrink App Store cards do while pressed.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
        .environmentObject(AppRouter())
}
