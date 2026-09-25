import SwiftUI
import SwiftData

/// Full Recently Viewed list: swipe or Edit to remove entries, or clear all.
struct RecentsView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecentApp.viewedAt, order: .reverse) private var recents: [RecentApp]
    @State private var confirmClear = false

    var body: some View {
        Group {
            if recents.isEmpty {
                ContentUnavailableView("No Recent Apps", systemImage: "clock",
                                       description: Text("Apps you open appear here."))
            } else {
                List {
                    ForEach(recents.uniqueByApp) { recent in
                        Button { router.homePath.append(.appDetail(id: recent.appID)) } label: {
                            AppRow(iconURL: recent.iconURL, name: recent.name,
                                   subtitle: recent.developerName ?? recent.bundleID) { Text("View") }
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recently Viewed")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !recents.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .confirmationDialog("Clear Recently Viewed?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                for recent in recents { modelContext.delete(recent) }
                try? modelContext.save()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let visible = recents.uniqueByApp
        for index in offsets {
            let appID = visible[index].appID
            for recent in recents where recent.appID == appID { modelContext.delete(recent) }
        }
        try? modelContext.save()
    }
}

extension Array where Element == RecentApp {
    /// Newest entry per app. Older builds inserted a row on every visit.
    var uniqueByApp: [RecentApp] {
        var seen = Set<Int64>()
        return filter { seen.insert($0.appID).inserted }
    }
}

extension RecentApp {
    /// Delete duplicate rows left behind by builds that recorded every visit,
    /// keeping the newest one per app.
    @MainActor
    static func removeDuplicates(in context: ModelContext) {
        let descriptor = FetchDescriptor<RecentApp>(sortBy: [SortDescriptor(\.viewedAt, order: .reverse)])
        guard let all = try? context.fetch(descriptor) else { return }
        var seen = Set<Int64>()
        var removed = false
        for recent in all where !seen.insert(recent.appID).inserted {
            context.delete(recent)
            removed = true
        }
        if removed { try? context.save() }
    }
}
