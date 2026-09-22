import SwiftUI
import SwiftData
import AppStoreCore

@main
struct iPullApp: App {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .environmentObject(router)
                .modelContainer(environment.modelContainer)
                .onOpenURL { url in
                    router.handleIncoming(url: url)
                }
                .onAppear {
                    environment.downloadManager.restoreState()
                    router.consumePendingShareExtensionURL()
                }
        }
    }
}
