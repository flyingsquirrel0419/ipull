import SwiftUI
import UIKit
import SwiftData
import AppStoreCore

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \RecentApp.viewedAt, order: .reverse) private var recents: [RecentApp]

    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $router.homePath) {
            List {
                Section {
                    TextField("Paste App Store link, App ID or Bundle ID", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(resolve)
                        .accessibilityLabel("App input")

                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            input = clipboard
                            resolve()
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if !recents.isEmpty {
                    Section("Recently Viewed") {
                        ForEach(recents.prefix(10)) { recent in
                            Button {
                                router.homePath.append(.appDetail(id: recent.appID))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(recent.name)
                                    if let developer = recent.developerName {
                                        Text(developer).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("Purchased") {
                        PurchasedView()
                    }
                }
            }
            .navigationTitle("iPull")
            .navigationDestination(for: AppRouter.Route.self) { route in
                switch route {
                case .appDetail(let id):
                    AppDetailView(appID: id)
                }
            }
        }
    }

    private func resolve() {
        errorMessage = nil
        switch AppStoreURLParser.parse(input) {
        case .success(let request):
            switch request {
            case .appStoreURL(let id, _), .appID(let id):
                router.homePath.append(.appDetail(id: id))
            case .bundleID, .searchTerm:
                router.selectedTab = .search
                NotificationCenter.default.post(name: .ipullSearchRequested, object: input)
            }
        case .failure(let error):
            errorMessage = error.userMessage
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppEnvironment())
        .environmentObject(AppRouter())
}
