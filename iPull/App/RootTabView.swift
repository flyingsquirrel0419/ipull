import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    /// Observed here so the Downloads tab badge counts live.
    @ObservedObject var downloads: DownloadManager

    private var activeDownloads: Int {
        downloads.records.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "square.grid.2x2.fill") }
                .tag(AppRouter.Tab.home)

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppRouter.Tab.search)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(AppRouter.Tab.library)

            DownloadsView(manager: environment.downloadManager)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                .badge(activeDownloads)
                .tag(AppRouter.Tab.downloads)

            SettingsView(presentedAsSheet: false)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .overlay {
            if let flight = router.flight {
                FlyingIconOverlay(flight: flight, tabIndex: 3, tabCount: 5) {
                    if router.flight == flight { router.flight = nil }
                }
                .id(flight.id)
            }
        }
        .sheet(isPresented: $router.isAccountPresented) {
            SettingsView()
        }
        .alert("Signed Out", isPresented: Binding(
            get: { environment.sessionNotice != nil },
            set: { if !$0 { environment.sessionNotice = nil } }
        )) {
            Button("Sign In") { router.isAccountPresented = true }
            Button("Later", role: .cancel) {}
        } message: {
            Text(environment.sessionNotice ?? "")
        }
    }
}

/// Shared destination table for the Home and Search navigation stacks.
struct RouteDestination: View {
    let route: AppRouter.Route

    var body: some View {
        switch route {
        case .appDetail(let id): AppDetailView(appID: id)
        case .recents: RecentsView()
        }
    }
}
