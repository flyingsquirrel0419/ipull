import SwiftUI
import SwiftData
import AppStoreCore

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LibraryItem.downloadedAt, order: .reverse) private var items: [LibraryItem]

    @State private var itemToShare: LibraryItem?
    @State private var itemToRename: LibraryItem?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No IPAs Yet", systemImage: "shippingbox",
                                           description: Text("Downloaded IPAs will appear here."))
                } else {
                    List {
                        ForEach(items) { item in
                            LibraryRow(item: item, storage: environment.storage)
                                .contextMenu { contextMenu(for: item) }
                                .swipeActions {
                                    Button(role: .destructive) { delete(item) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(ByteFormat.string(environment.storage.totalStorageBytes()))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .sheet(item: $itemToShare) { item in
                ShareSheetView(items: [environment.storage.absoluteURL(forRelative: item.relativeFilePath)])
            }
            .alert("Rename", isPresented: Binding(
                get: { itemToRename != nil },
                set: { if !$0 { itemToRename = nil } }
            )) {
                TextField("File name", text: $renameText)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) { itemToRename = nil }
            }
            .alert("Library", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: LibraryItem) -> some View {
        Button { itemToShare = item } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { saveToFiles(item) } label: { Label("Save to Files", systemImage: "folder") }
        Button {
            renameText = FileNaming.ipaFileName(appName: item.appName, version: item.version)
            itemToRename = item
        } label: { Label("Rename", systemImage: "pencil") }
        Button { verifyHash(item) } label: { Label("Verify SHA-256", systemImage: "checkmark.seal") }
        Divider()
        Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    private func saveToFiles(_ item: LibraryItem) {
        // The share sheet with "Save to Files" is the supported export path;
        // present it pre-targeted.
        itemToShare = item
    }

    private func rename() {
        guard let item = itemToRename else { return }
        let sanitized = FileNaming.sanitize(renameText.replacingOccurrences(of: ".ipa", with: ""))
        guard !sanitized.isEmpty else { itemToRename = nil; return }
        let current = environment.storage.absoluteURL(forRelative: item.relativeFilePath)
        let destination = current.deletingLastPathComponent()
            .appendingPathComponent(sanitized + ".ipa")
        do {
            try FileManager.default.moveItem(at: current, to: destination)
            item.relativeFilePath = environment.storage.relativePath(forAbsolute: destination)
            try? modelContext.save()
        } catch {
            errorMessage = AppStoreError.fileWriteFailed.userMessage
        }
        itemToRename = nil
    }

    private func verifyHash(_ item: LibraryItem) {
        let url = environment.storage.absoluteURL(forRelative: item.relativeFilePath)
        Task.detached(priority: .utility) {
            let hash = try? SHA256Streamer.hash(fileAt: url)
            await MainActor.run {
                if let hash {
                    item.sha256 = hash
                    try? modelContext.save()
                    errorMessage = "SHA-256 verified: \(hash.prefix(16))…"
                } else {
                    errorMessage = "Couldn't read the file."
                }
            }
        }
    }

    private func delete(_ item: LibraryItem) {
        let url = environment.storage.absoluteURL(forRelative: item.relativeFilePath)
        try? FileManager.default.removeItem(at: url)
        // Remove the now-empty version directory.
        let dir = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
        modelContext.delete(item)
        try? modelContext.save()
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    let storage: IPAStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.appName).font(.body)
            Text(item.version).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(ByteFormat.string(item.fileSizeBytes))
                Text("·")
                Text(item.downloadedAt, style: .date)
            }
            .font(.caption).foregroundStyle(.secondary)
            if let sha = item.sha256 {
                Text("SHA-256 \(sha.prefix(16))…")
                    .font(.caption2).foregroundStyle(.tertiary).monospaced()
            }
        }
        .padding(.vertical, 2)
    }
}

/// UIActivityViewController wrapper (Share / Save to Files / AirDrop).
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
