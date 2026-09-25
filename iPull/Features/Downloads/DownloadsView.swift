import AppStoreCore
import SwiftUI

struct DownloadsView: View {
    /// Observed directly: DownloadManager is its own ObservableObject, and
    /// reading it through AppEnvironment never refreshed progress or state.
    @ObservedObject var manager: DownloadManager

    var body: some View {
        NavigationStack {
            let records = manager.records
            Group {
                if records.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Apps you download appear here while they transfer.")
                    }
                } else {
                    List {
                        let active = records.filter { $0.state == .downloading || $0.state == .queued }
                        let failed = records.filter { $0.state == .failed || $0.state == .cancelled }
                        let completed = records.filter { $0.state == .completed }

                        if !active.isEmpty { Section("In Progress") { ForEach(active) { row($0) } } }
                        if !failed.isEmpty { Section("Needs Attention") { ForEach(failed) { row($0) } } }
                        if !completed.isEmpty { Section("Completed") { ForEach(completed) { row($0) } } }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .toolbar { AccountToolbarButton() }
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 14) {
            AppIconView(url: record.iconURL, name: record.appName, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.appName).font(.body.weight(.semibold)).lineLimit(1)
                subtitle(record)
            }
            Spacer(minLength: 8)
            trailing(record)
        }
        .padding(.vertical, 4)
        .swipeActions {
            if record.state != .downloading {
                Button(role: .destructive) { manager.remove(record.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func subtitle(_ record: DownloadRecord) -> some View {
        switch record.state {
        case .downloading:
            let progress = manager.progress[record.id]
            let done = ByteFormat.string(progress?.bytesDownloaded ?? record.bytesDownloaded)
            let total = ByteFormat.string(progress?.totalBytes ?? record.totalBytes)
            if let speed = progress?.bytesPerSecond, speed > 0 {
                Text("\(done) of \(total) · \(ByteFormat.string(Int64(speed)))/s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("\(done) of \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .queued:
            Text("Waiting · Version \(record.version)").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(record.failureReason ?? AppStoreErrorCore.downloadFailedMessage)
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        default:
            if let folder = record.savedFolderName {
                Label("Saved to \(folder)", systemImage: "folder.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Version \(record.version) · In Library").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trailing(_ record: DownloadRecord) -> some View {
        switch record.state {
        case .downloading:
            Button { manager.cancel(record.id) } label: {
                DownloadRing(fraction: manager.progress[record.id]?.fraction ?? record.progress)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop download")
        case .queued:
            ProgressView()
        case .failed, .cancelled:
            Button("Retry") { manager.retry(record.id) }.buttonStyle(.pill)
        default:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityLabel("Completed")
        }
    }
}

enum AppStoreErrorCore {
    static let downloadFailedMessage = "The download failed. You can retry it."
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
