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
                    ForEach(recents) { recent in
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
        for index in offsets { modelContext.delete(recents[index]) }
        try? modelContext.save()
    }
}
