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
                .searchable(text: $viewModel.query, prompt: "App name")
                .onSubmit(of: .search) { Task { await viewModel.search(environment: environment) } }
                .onReceive(NotificationCenter.default.publisher(for: .ipullSearchRequested)) { note in
                    if let input = note.object as? String {
                        viewModel.query = input
                        Task { await viewModel.search(environment: environment) }
                    }
                }
                .navigationDestination(for: AppRouter.Route.self) { route in
                    switch route {
                    case .appDetail(let id): AppDetailView(appID: id)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ContentUnavailableView(
                "Search the App Store",
                systemImage: "magnifyingglass",
                description: Text("Search by app name to find an app.")
            )
        case .loading:
            ProgressView("Searching…")
        case .loaded(let apps):
            if apps.isEmpty {
                ContentUnavailableView.search(text: viewModel.query)
            } else {
                List(apps) { app in
                    Button {
                        router.searchPath.append(.appDetail(id: app.id))
                    } label: {
                        SearchResultRow(app: app)
                    }
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Search Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

struct SearchResultRow: View {
    let app: AppStoreApp

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body).foregroundStyle(.primary)
                Text(app.developerName ?? "").font(.caption).foregroundStyle(.secondary)
                Text(app.bundleID).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
