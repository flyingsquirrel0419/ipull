import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment

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
                .tag(AppRouter.Tab.downloads)
        }
        .sheet(isPresented: $router.isAccountPresented) {
            SettingsView()
        }
    }
}

/// Shared destination table for the Home and Search navigation stacks.
struct RouteDestination: View {
    let route: AppRouter.Route

    var body: some View {
        switch route {
        case .appDetail(let id): AppDetailView(appID: id)
        case .purchased: PurchasedView()
        case .recents: RecentsView()
        }
    }
}
