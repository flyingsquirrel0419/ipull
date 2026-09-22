import SwiftUI
import AppStoreCore

struct PurchasedView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @StateObject private var viewModel = PurchasedViewModel()

    var body: some View {
        Group {
            switch viewModel.state {
            case .requiresSignIn:
                ContentUnavailableView("Sign In Required", systemImage: "person.crop.circle",
                                       description: Text("Sign in to see apps on your Apple Account."))
            case .loading:
                ProgressView("Loading purchased apps…")
            case .unavailable(let message):
                ContentUnavailableView("Purchased Unavailable", systemImage: "bag.badge.questionmark",
                                       description: Text(message))
            case .loaded(let apps):
                if apps.isEmpty {
                    ContentUnavailableView("No Apps Found", systemImage: "bag",
                                           description: Text("No purchased apps were returned for this account."))
                } else {
                    List(viewModel.filtered(apps)) { app in
                        Button { router.homePath.append(.appDetail(id: app.id)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundStyle(.primary)
                                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .searchable(text: $viewModel.query, prompt: "Search purchased apps")
                }
            }
        }
        .navigationTitle("Purchased")
        .task { await viewModel.load(environment: environment) }
    }
}

@MainActor
final class PurchasedViewModel: ObservableObject {
    enum State: Equatable {
        case requiresSignIn, loading
        case unavailable(String)
        case loaded([AppStoreApp])
    }

    @Published var query = ""
    @Published private(set) var state: State = .loading

    func filtered(_ apps: [AppStoreApp]) -> [AppStoreApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    func load(environment: AppEnvironment) async {
        guard let session = environment.session else {
            state = .requiresSignIn
            return
        }
        state = .loading
        do {
            let page = try await environment.client.ownedApps.ownedApps(session: session, page: 0, limit: 100)
            state = .loaded(page.apps)
        } catch let error as AppStoreError {
            state = error.requiresReauthentication ? .requiresSignIn : .unavailable(error.userMessage)
        } catch {
            state = .unavailable("The purchased-apps endpoint is unavailable. Search still works.")
        }
    }
}
