import SwiftUI
import AppStoreCore

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            content
                .navigationTitle("Search")
                .toolbar { AccountToolbarButton() }
                .searchable(text: $viewModel.query,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Apps, bundle IDs and more")
                .onSubmit(of: .search) { submit() }
                .onChange(of: router.pendingSearch, initial: true) { _, term in
                    guard let term, !term.isEmpty else { return }
                    router.pendingSearch = nil
                    viewModel.query = term
                    viewModel.submit(environment: environment)
                }
                .navigationDestination(for: AppRouter.Route.self) { RouteDestination(route: $0) }
        }
    }

    /// Links and App IDs typed here open the app, as on Home.
    private func submit() {
        switch AppStoreURLParser.parse(viewModel.query) {
        case .success(.appStoreURL(let id, _)), .success(.appID(let id)):
            router.searchPath.append(.appDetail(id: id))
        default:
            viewModel.submit(environment: environment)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView {
                Label("Find Any App", systemImage: "magnifyingglass")
            } description: {
                Text("Search by name, or paste a bundle ID such as com.apple.Pages.")
            }
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let apps):
            if apps.isEmpty {
                ContentUnavailableView.search(text: viewModel.query)
            } else {
                List(apps) { app in
                    Button { router.searchPath.append(.appDetail(id: app.id)) } label: {
                        SearchResultRow(app: app)
                    }
                    .buttonStyle(.plain)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                }
                .listStyle(.plain)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { submit() }
                    .buttonStyle(.pill)
            }
        }
    }
}

struct SearchResultRow: View {
    let app: AppStoreApp

    var body: some View {
        AppRow(iconURL: app.iconURL, name: app.name,
               subtitle: app.developerName ?? app.bundleID,
               detail: app.developerName == nil ? nil : app.bundleID) {
            Text("View")
        }
    }
}
