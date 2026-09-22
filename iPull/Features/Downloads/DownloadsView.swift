import AppStoreCore
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            let records = environment.downloadManager.records
            Group {
                if records.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("IPAs you download will appear here."))
                } else {
                    List {
                        let downloading = records.filter { $0.state == .downloading }
                        let queued = records.filter { $0.state == .queued }
                        let completed = records.filter { $0.state == .completed }
                        let failed = records.filter { $0.state == .failed || $0.state == .cancelled }

                        if !downloading.isEmpty { Section("Downloading") { ForEach(downloading) { row($0) } } }
                        if !queued.isEmpty { Section("Queued") { ForEach(queued) { row($0) } } }
                        if !failed.isEmpty { Section("Failed") { ForEach(failed) { row($0) } } }
                        if !completed.isEmpty { Section("Completed") { ForEach(completed) { row($0) } } }
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }

    @ViewBuilder
    private func row(_ record: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.appName).font(.body)
                Spacer()
                Text(record.version).font(.subheadline).foregroundStyle(.secondary)
            }

            switch record.state {
            case .downloading:
                let progress = environment.downloadManager.progress[record.id]
                ProgressView(value: progress?.fraction ?? record.progress)
                HStack {
                    Text(ByteFormat.string(progress?.bytesDownloaded ?? record.bytesDownloaded))
                    Text("/")
                    Text(ByteFormat.string(progress?.totalBytes ?? record.totalBytes))
                    Spacer()
                    if let speed = progress?.bytesPerSecond, speed > 0 {
                        Text("\(ByteFormat.string(Int64(speed)))/s").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .failed:
                Text(record.failureReason ?? AppStoreErrorCore.downloadFailedMessage)
                    .font(.caption).foregroundStyle(.red)
            case .queued:
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }

            HStack {
                if record.state == .downloading {
                    Button("Cancel") { environment.downloadManager.cancel(record.id) }
                        .buttonStyle(.bordered)
                }
                if record.state == .failed || record.state == .cancelled {
                    Button("Retry") { environment.downloadManager.retry(record.id) }
                        .buttonStyle(.bordered)
                }
                if record.state != .downloading {
                    Button("Remove", role: .destructive) { environment.downloadManager.remove(record.id) }
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
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
