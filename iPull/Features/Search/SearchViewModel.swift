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

    func search(environment: AppEnvironment) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { state = .idle; return }

        state = .loading
        let country = environment.session?.countryCode ?? "us"
        do {
            // Bundle-ID-shaped input resolves directly for precision.
            if AppStoreURLParser.isPlausibleBundleID(term) {
                let app = try await environment.client.search.lookup(bundleID: term, countryCode: country)
                state = .loaded([app])
            } else {
                let apps = try await environment.client.search.search(term: term, countryCode: country, limit: 25)
                state = .loaded(apps)
            }
        } catch let error as AppStoreError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(AppStoreError.unknown("search").userMessage)
        }
    }
}
