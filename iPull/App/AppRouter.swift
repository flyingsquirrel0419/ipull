import Foundation
import AppStoreCore

/// App Group shared with the Share Extension for URL handoff.
public enum AppGroup {
    public static let identifier = "group.com.ipull.app"
    public static let sharedURLKey = "pending-appstore-url"

    public static var container: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

/// Navigation + deep link coordination.
@MainActor
public final class AppRouter: ObservableObject {
    public enum Route: Hashable {
        case appDetail(id: Int64)
        case purchased
        case recents
    }

    @Published public var homePath: [Route] = []
    @Published public var searchPath: [Route] = []
    @Published public var selectedTab: Tab = .home
    /// The account sheet (sign-in, storage, diagnostics), opened from the
    /// profile button on every tab or from any "Sign In" prompt.
    @Published public var isAccountPresented = false
    /// A search handed over from Home or the Share Extension. Held here
    /// rather than broadcast, because the Search tab's view may not exist
    /// yet when the request is made; it consumes this once it appears.
    @Published public var pendingSearch: String?

    public enum Tab: Hashable {
        case home, search, library, downloads, settings
    }

    /// Handle ipull:// deep links and App Group handoffs from the Share
    /// Extension. The extension writes the App Store URL into the group
    /// container, then opens ipull://resolve; we read and route.
    public func handleIncoming(url: URL) {
        guard url.scheme == "ipull" else { return }
        switch url.host {
        case "resolve":
            consumePendingShareExtensionURL()
        default:
            break
        }
    }

    public func consumePendingShareExtensionURL() {
        guard let defaults = AppGroup.container,
              let urlString = defaults.string(forKey: AppGroup.sharedURLKey)
        else { return }
        defaults.removeObject(forKey: AppGroup.sharedURLKey)
        routeToApp(input: urlString)
    }

    /// Parse user input (or a shared URL) and navigate to App Detail when
    /// it identifies a concrete app.
    @discardableResult
    public func routeToApp(input: String) -> AppLookupRequest? {
        guard case .success(let request) = AppStoreURLParser.parse(input) else { return nil }
        switch request {
        case .appStoreURL(let id, _), .appID(let id):
            selectedTab = .home
            homePath.append(.appDetail(id: id))
        case .bundleID, .searchTerm:
            search(input)
        }
        return request
    }

    /// Switch to the Search tab and run `term` there verbatim.
    public func search(_ term: String) {
        searchPath = []
        selectedTab = .search
        pendingSearch = term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
