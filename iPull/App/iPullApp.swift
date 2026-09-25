import SwiftUI
import SwiftData
import AppStoreCore

#if canImport(Darwin)
import Darwin
#endif

/// Installs last-resort crash reporting. LiveContainer kills the process
/// without producing an iPull crash report, so uncaught exceptions and
/// fatal signals are written to the on-device log file before the process
/// dies. Nothing sensitive is logged — only the exception/signal name.
enum CrashReporter {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            Log.error(.ui, "uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(sig) { code in
                Log.error(.ui, "fatal signal \(code); process will exit")
                signal(code, SIG_DFL)
                raise(code)
            }
        }
    }
}

@main
struct iPullApp: App {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var router = AppRouter()

    init() {
        CrashReporter.install()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(downloads: environment.downloadManager)
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
