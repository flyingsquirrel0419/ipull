import Foundation
import AppStoreCore

@MainActor
final class SearchViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([AppStoreApp])
        case failed(String)
    }

    @Published var query = ""
    @Published private(set) var state: State = .idle
    private var searchTask: Task<Void, Never>?

    /// Starts a search, cancelling one still in flight so a slow earlier
    /// response can never overwrite the results of a newer query.
    func submit(environment: AppEnvironment) {
        searchTask?.cancel()
        searchTask = Task { await search(environment: environment) }
    }

    func search(environment: AppEnvironment) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { state = .idle; return }

        state = .loading
        let country = environment.session?.countryCode ?? "us"
        do {
            // Bundle-ID-shaped input resolves directly for precision.
            let apps: [AppStoreApp]
            if AppStoreURLParser.isPlausibleBundleID(term) {
                apps = [try await environment.client.search.lookup(bundleID: term, countryCode: country)]
            } else {
                apps = try await environment.client.search.search(term: term, countryCode: country, limit: 25)
            }
            guard !Task.isCancelled else { return }
            state = .loaded(apps)
        } catch is CancellationError {
            return
        } catch let error as AppStoreError {
            guard !Task.isCancelled else { return }
            state = .failed(error.userMessage)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(AppStoreError.unknown("search").userMessage)
        }
    }
}
